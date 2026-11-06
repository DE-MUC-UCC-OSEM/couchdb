// couchdb-launcher is the entrypoint of the CouchDB image. The image has no
// bash and no coreutils, so this static binary replaces docker-entrypoint.sh,
// the chroot call that dropped the privileges and the bin/couchdb start script:
//
//  1. write the configuration from the environment to etc/default.d
//  2. write -name and -setcookie to etc/vm.runtime.args
//  3. as root: give data, etc and var to couchdb (5984) and drop to that user
//  4. exec erlexec with the same arguments and environment as bin/couchdb
//
// Environment: SINGLE_NODE, COUCHDB_SHARDS, COUCHDB_USER, COUCHDB_PASSWORD,
// COUCHDB_SECRET, NODENAME and ERLANG_COOKIE (see README.md), plus the
// variables of bin/couchdb: COUCHDB_ARGS_FILE, COUCHDB_INI_FILES,
// COUCHDB_SYSCONFIG_FILE and COUCHDB_FAUXTON_DOCROOT. Arguments are passed on
// to erlexec.
package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const (
	rootDir         = "/opt/couchdb"
	couchdbID       = 5984 // uid and gid of the couchdb user
	defaultCookie   = "erlang-magic-cookie"
	runtimeArgsName = "vm.runtime.args"
)

// ownedDirs are the directories below the root that CouchDB writes to. The
// rest of the release stays owned by root, so CouchDB cannot change its own
// runtime.
var ownedDirs = []string{"data", "etc", "var"}

type launcher struct {
	root    string
	getenv  func(string) string
	environ []string
	stderr  io.Writer
	isRoot  bool
	lchown  func(path string, uid, gid int) error
	drop    func() error
	exec    func(dir, argv0 string, argv, env []string) error
}

type file struct {
	name    string
	content string
	mode    fs.FileMode
}

// configFiles returns the files for etc/default.d, same names and content as
// the former docker-entrypoint.sh, and the files of the other cluster mode
// that have to be removed.
func configFiles(getenv func(string) string) (files []file, stale []string, err error) {
	for _, name := range []string{"COUCHDB_SHARDS", "COUCHDB_USER", "COUCHDB_PASSWORD", "COUCHDB_SECRET"} {
		if strings.ContainsAny(getenv(name), "\r\n") {
			return nil, nil, fmt.Errorf("%s must not contain line breaks", name)
		}
	}
	if getenv("SINGLE_NODE") != "" {
		files = append(files, file{"00-single.ini", "[couchdb]\nsingle_node = true\n\n[cluster]\nn = 1\n", 0o644})
		stale = append(stale, "00-cluster.ini")
	} else {
		shards := getenv("COUCHDB_SHARDS")
		if shards == "" {
			shards = "4"
		}
		files = append(files, file{"00-cluster.ini", "[cluster]\nn = 3\nreconnect_interval_sec = 10\nq = " + shards + "\n", 0o644})
		stale = append(stale, "00-single.ini")
	}
	if user, password := getenv("COUCHDB_USER"), getenv("COUCHDB_PASSWORD"); user != "" && password != "" {
		files = append(files, file{"99-creds.ini", "[admins]\n" + user + " = " + password + "\n", 0o600})
	}
	if secret := getenv("COUCHDB_SECRET"); secret != "" {
		files = append(files, file{"99-secret.ini", "[chttpd_auth]\nsecret = " + secret + "\n", 0o600})
	}
	files = append(files,
		file{"10-binding.ini", "[chttpd]\nbind_address = 0.0.0.0\nport = 5984\n", 0o644},
		file{"10-quickjs.ini", "[couchdb]\njs_engine = quickjs\n", 0o644},
		file{"10-size.ini", "[couchdb]\nmax_document_size = 25000000\n", 0o644},
		file{"10-logging.ini", "[log]\nwriter = stdout\n", 0o644},
	)
	return files, stale, nil
}

// runtimeArgs returns the content of etc/vm.runtime.args. Without
// ERLANG_COOKIE the default cookie of the former docker-entrypoint.sh is used.
func runtimeArgs(getenv func(string) string, stderr io.Writer) (string, error) {
	node := getenv("NODENAME")
	if node == "" {
		node = "localhost"
	}
	if strings.ContainsAny(node, " \t\r\n'\"") {
		return "", errors.New("NODENAME must not contain blanks, quotes or line breaks")
	}
	cookie := getenv("ERLANG_COOKIE")
	if cookie == "" {
		fmt.Fprintf(stderr, "couchdb-launcher: warning: ERLANG_COOKIE is not set, using the default cookie %q. Set ERLANG_COOKIE to a random value.\n", defaultCookie)
		cookie = defaultCookie
	}
	if strings.ContainsAny(cookie, "'\r\n") {
		return "", errors.New("ERLANG_COOKIE must not contain single quotes or line breaks")
	}
	return "-name couchdb@" + node + "\n-setcookie '" + cookie + "'\n", nil
}

// command returns the erlexec call of bin/couchdb.
func command(root string, getenv func(string) string, environ, args []string) (string, []string, []string, error) {
	data, err := os.ReadFile(filepath.Join(root, "releases", "start_erl.data"))
	if err != nil {
		return "", nil, nil, err
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return "", nil, nil, errors.New("releases/start_erl.data is empty")
	}
	bindir := filepath.Join(root, "erts-"+fields[0], "bin")
	erlexec := filepath.Join(bindir, "erlexec")

	argsFile := getenv("COUCHDB_ARGS_FILE")
	if argsFile == "" {
		argsFile = filepath.Join(root, "etc", "vm.args")
	}
	sysConfig := getenv("COUCHDB_SYSCONFIG_FILE")
	if sysConfig == "" {
		sysConfig = filepath.Join(root, "releases", "sys.config")
	}
	argv := []string{erlexec,
		"-boot", filepath.Join(root, "releases", "couchdb"),
		"-args_file", argsFile,
		"-args_file", filepath.Join(root, "etc", runtimeArgsName),
	}
	if ini := strings.Fields(getenv("COUCHDB_INI_FILES")); len(ini) > 0 {
		argv = append(argv, "-couch_ini")
		argv = append(argv, ini...)
	}
	argv = append(argv, "-config", sysConfig)
	argv = append(argv, args...)

	env := setenv(environ, "ROOTDIR", root)
	env = setenv(env, "BINDIR", bindir)
	env = setenv(env, "EMU", "beam")
	env = setenv(env, "PROGNAME", "couchdb")
	if getenv("COUCHDB_FAUXTON_DOCROOT") == "" {
		env = setenv(env, "COUCHDB_FAUXTON_DOCROOT", "./share/www")
	}
	if getenv("ERL_CRASH_DUMP") == "" {
		// The working directory belongs to root, var belongs to couchdb.
		env = setenv(env, "ERL_CRASH_DUMP", filepath.Join(root, "var", "erl_crash.dump"))
	}
	return erlexec, argv, env, nil
}

// setenv returns env with NAME=value, replacing an existing NAME.
func setenv(env []string, name, value string) []string {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		if !strings.HasPrefix(kv, name+"=") {
			out = append(out, kv)
		}
	}
	return append(out, name+"="+value)
}

// realDir fails if path is not a directory. A symbolic link is refused, so the
// launcher running as root never writes through a link that CouchDB placed.
func realDir(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	return nil
}

// writeFile replaces path with a new file. An existing file or symbolic link is
// removed first, so a link is never followed.
func writeFile(path, content string, mode fs.FileMode) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, mode)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// chownTree gives dir and everything below it to couchdb. Symbolic links are
// not followed. Read-only mounts (e.g. a Kubernetes configMap) are skipped.
func (l *launcher) chownTree(dir string) error {
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if path == dir && errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if err := l.lchown(path, couchdbID, couchdbID); err != nil {
			if !errors.Is(err, syscall.EROFS) {
				return err
			}
			fmt.Fprintf(l.stderr, "couchdb-launcher: %s is read-only, owner not changed\n", path)
			if d.IsDir() {
				return fs.SkipDir
			}
		}
		return nil
	})
}

func (l *launcher) run(args []string) error {
	argv0, argv, env, err := command(l.root, l.getenv, l.environ, args)
	if err != nil {
		return err
	}
	files, stale, err := configFiles(l.getenv)
	if err != nil {
		return err
	}
	vmArgs, err := runtimeArgs(l.getenv, l.stderr)
	if err != nil {
		return err
	}

	etc := filepath.Join(l.root, "etc")
	defaultDir := filepath.Join(etc, "default.d")
	if err := realDir(etc); err != nil {
		return err
	}
	if err := os.Mkdir(defaultDir, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	if err := realDir(defaultDir); err != nil {
		return err
	}
	for _, name := range stale {
		if err := os.Remove(filepath.Join(defaultDir, name)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	for _, f := range files {
		if err := writeFile(filepath.Join(defaultDir, f.name), f.content, f.mode); err != nil {
			return err
		}
	}
	// Contains the cookie, so only readable by its owner.
	if err := writeFile(filepath.Join(etc, runtimeArgsName), vmArgs, 0o600); err != nil {
		return err
	}

	if l.isRoot {
		for _, dir := range ownedDirs {
			if err := l.chownTree(filepath.Join(l.root, dir)); err != nil {
				return err
			}
		}
		if err := l.drop(); err != nil {
			return fmt.Errorf("drop privileges: %w", err)
		}
	}
	return l.exec(l.root, argv0, argv, env)
}

func dropPrivileges() error {
	if err := syscall.Setgroups([]int{}); err != nil {
		return err
	}
	if err := syscall.Setgid(couchdbID); err != nil {
		return err
	}
	return syscall.Setuid(couchdbID)
}

func execIn(dir, argv0 string, argv, env []string) error {
	if err := os.Chdir(dir); err != nil {
		return err
	}
	return syscall.Exec(argv0, argv, env)
}

func main() {
	l := &launcher{
		root:    rootDir,
		getenv:  os.Getenv,
		environ: os.Environ(),
		stderr:  os.Stderr,
		isRoot:  os.Getuid() == 0,
		lchown:  os.Lchown,
		drop:    dropPrivileges,
		exec:    execIn,
	}
	if err := l.run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "couchdb-launcher:", err)
		os.Exit(1)
	}
}
