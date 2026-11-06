package main

import (
	"bytes"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"testing"
)

func envMap(m map[string]string) func(string) string {
	return func(name string) string { return m[name] }
}

// release creates a minimal CouchDB release below a temporary directory.
func release(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, dir := range []string{"etc/default.d", "etc/local.d", "releases", "data/shards", "var", "lib/couch-3.5.3"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeTestFile(t, filepath.Join(root, "releases", "start_erl.data"), "15.2.7.14 3.5.3\n")
	writeTestFile(t, filepath.Join(root, "etc", "vm.args"), "+Bd -noinput\n")
	writeTestFile(t, filepath.Join(root, "data", "_dbs.couch"), "")
	return root
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readTestFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

type execCall struct {
	dir, argv0 string
	argv, env  []string
}

func newLauncher(root string, env map[string]string) (*launcher, *execCall, *bytes.Buffer) {
	call := &execCall{}
	stderr := &bytes.Buffer{}
	environ := []string{"PATH=/usr/bin"}
	for k, v := range env {
		environ = append(environ, k+"="+v)
	}
	l := &launcher{
		root:    root,
		getenv:  envMap(env),
		environ: environ,
		stderr:  stderr,
		lchown:  func(string, int, int) error { panic("lchown must not be called") },
		drop:    func() error { panic("drop must not be called") },
		exec: func(dir, argv0 string, argv, env []string) error {
			*call = execCall{dir, argv0, argv, env}
			return nil
		},
	}
	return l, call, stderr
}

func TestConfigFilesSingleNode(t *testing.T) {
	files, stale, err := configFiles(envMap(map[string]string{
		"SINGLE_NODE":      "true",
		"COUCHDB_USER":     "admin",
		"COUCHDB_PASSWORD": "pw",
		"COUCHDB_SECRET":   "s3cr3t",
	}))
	if err != nil {
		t.Fatal(err)
	}
	want := []file{
		{"00-single.ini", "[couchdb]\nsingle_node = true\n\n[cluster]\nn = 1\n", 0o644},
		{"99-creds.ini", "[admins]\nadmin = pw\n", 0o600},
		{"99-secret.ini", "[chttpd_auth]\nsecret = s3cr3t\n", 0o600},
		{"10-binding.ini", "[chttpd]\nbind_address = 0.0.0.0\nport = 5984\n", 0o644},
		{"10-quickjs.ini", "[couchdb]\njs_engine = quickjs\n", 0o644},
		{"10-size.ini", "[couchdb]\nmax_document_size = 25000000\n", 0o644},
		{"10-logging.ini", "[log]\nwriter = stdout\n", 0o644},
	}
	if !reflect.DeepEqual(files, want) {
		t.Errorf("files\n got %v\nwant %v", files, want)
	}
	if !reflect.DeepEqual(stale, []string{"00-cluster.ini"}) {
		t.Errorf("stale %v", stale)
	}
}

func TestConfigFilesCluster(t *testing.T) {
	for shards, q := range map[string]string{"": "4", "8": "8"} {
		files, stale, err := configFiles(envMap(map[string]string{"COUCHDB_SHARDS": shards}))
		if err != nil {
			t.Fatal(err)
		}
		want := file{"00-cluster.ini", "[cluster]\nn = 3\nreconnect_interval_sec = 10\nq = " + q + "\n", 0o644}
		if files[0] != want {
			t.Errorf("COUCHDB_SHARDS=%q: got %v, want %v", shards, files[0], want)
		}
		if !reflect.DeepEqual(stale, []string{"00-single.ini"}) {
			t.Errorf("stale %v", stale)
		}
	}
}

func TestConfigFilesCredentialsNeedUserAndPassword(t *testing.T) {
	for _, env := range []map[string]string{{"COUCHDB_USER": "admin"}, {"COUCHDB_PASSWORD": "pw"}} {
		files, _, err := configFiles(envMap(env))
		if err != nil {
			t.Fatal(err)
		}
		for _, f := range files {
			if f.name == "99-creds.ini" || f.name == "99-secret.ini" {
				t.Errorf("env %v: unexpected %s", env, f.name)
			}
		}
	}
}

func TestConfigFilesRejectLineBreaks(t *testing.T) {
	for _, name := range []string{"COUCHDB_SHARDS", "COUCHDB_USER", "COUCHDB_PASSWORD", "COUCHDB_SECRET"} {
		if _, _, err := configFiles(envMap(map[string]string{name: "a\n[admins]\nx = y"})); err == nil {
			t.Errorf("%s with a line break: no error", name)
		}
	}
}

func TestRuntimeArgs(t *testing.T) {
	var stderr bytes.Buffer
	got, err := runtimeArgs(envMap(map[string]string{"NODENAME": "couchdb-0.local", "ERLANG_COOKIE": "abc123"}), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if want := "-name couchdb@couchdb-0.local\n-setcookie 'abc123'\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if stderr.Len() != 0 {
		t.Errorf("unexpected warning %q", stderr.String())
	}
}

func TestRuntimeArgsDefaults(t *testing.T) {
	var stderr bytes.Buffer
	got, err := runtimeArgs(envMap(nil), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	if want := "-name couchdb@localhost\n-setcookie 'erlang-magic-cookie'\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if !strings.Contains(stderr.String(), "ERLANG_COOKIE is not set") {
		t.Errorf("missing warning, stderr %q", stderr.String())
	}
}

func TestRuntimeArgsRejectInvalid(t *testing.T) {
	for _, env := range []map[string]string{
		{"ERLANG_COOKIE": "it's"},
		{"ERLANG_COOKIE": "a\nb"},
		{"NODENAME": "a b"},
		{"NODENAME": "a\n-setcookie x"},
	} {
		if _, err := runtimeArgs(envMap(env), io.Discard); err == nil {
			t.Errorf("env %v: no error", env)
		}
	}
}

func TestRun(t *testing.T) {
	root := release(t)
	defaultDir := filepath.Join(root, "etc", "default.d")
	writeTestFile(t, filepath.Join(defaultDir, "00-cluster.ini"), "stale")
	l, call, _ := newLauncher(root, map[string]string{
		"SINGLE_NODE":       "true",
		"COUCHDB_USER":      "admin",
		"COUCHDB_PASSWORD":  "pw",
		"NODENAME":          "127.0.0.1",
		"ERLANG_COOKIE":     "c00kie",
		"COUCHDB_INI_FILES": "/a.ini  /b.ini",
	})
	if err := l.run([]string{"-extra"}); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(defaultDir, "00-cluster.ini")); !os.IsNotExist(err) {
		t.Errorf("00-cluster.ini not removed: %v", err)
	}
	if got := readTestFile(t, filepath.Join(defaultDir, "99-creds.ini")); got != "[admins]\nadmin = pw\n" {
		t.Errorf("99-creds.ini %q", got)
	}
	for name, mode := range map[string]fs.FileMode{
		"etc/default.d/99-creds.ini":   0o600,
		"etc/default.d/10-binding.ini": 0o644,
		"etc/vm.runtime.args":          0o600,
	} {
		fi, err := os.Stat(filepath.Join(root, name))
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm() != mode {
			t.Errorf("%s mode %v, want %v", name, fi.Mode().Perm(), mode)
		}
	}
	if got := readTestFile(t, filepath.Join(root, "etc", "vm.args")); got != "+Bd -noinput\n" {
		t.Errorf("vm.args changed: %q", got)
	}

	bindir := filepath.Join(root, "erts-15.2.7.14", "bin")
	wantArgv := []string{
		filepath.Join(bindir, "erlexec"),
		"-boot", filepath.Join(root, "releases", "couchdb"),
		"-args_file", filepath.Join(root, "etc", "vm.args"),
		"-args_file", filepath.Join(root, "etc", "vm.runtime.args"),
		"-couch_ini", "/a.ini", "/b.ini",
		"-config", filepath.Join(root, "releases", "sys.config"),
		"-extra",
	}
	if call.dir != root || call.argv0 != wantArgv[0] || !reflect.DeepEqual(call.argv, wantArgv) {
		t.Errorf("exec\n got %q %q %q\nwant %q %q %q", call.dir, call.argv0, call.argv, root, wantArgv[0], wantArgv)
	}
	for _, kv := range []string{
		"PATH=/usr/bin",
		"ROOTDIR=" + root,
		"BINDIR=" + bindir,
		"EMU=beam",
		"PROGNAME=couchdb",
		"COUCHDB_FAUXTON_DOCROOT=./share/www",
		"ERL_CRASH_DUMP=" + filepath.Join(root, "var", "erl_crash.dump"),
		"ERLANG_COOKIE=c00kie",
	} {
		if !slices.Contains(call.env, kv) {
			t.Errorf("env misses %s: %q", kv, call.env)
		}
	}
}

func TestRunKeepsCallerSettings(t *testing.T) {
	root := release(t)
	l, call, _ := newLauncher(root, map[string]string{
		"COUCHDB_ARGS_FILE":       "/custom/vm.args",
		"COUCHDB_SYSCONFIG_FILE":  "/custom/sys.config",
		"COUCHDB_FAUXTON_DOCROOT": "/www",
		"ERL_CRASH_DUMP":          "/dump",
		"ROOTDIR":                 "/wrong",
	})
	if err := l.run(nil); err != nil {
		t.Fatal(err)
	}
	if call.argv[4] != "/custom/vm.args" || call.argv[len(call.argv)-1] != "/custom/sys.config" {
		t.Errorf("argv %q", call.argv)
	}
	for _, kv := range []string{"COUCHDB_FAUXTON_DOCROOT=/www", "ERL_CRASH_DUMP=/dump", "ROOTDIR=" + root} {
		if !slices.Contains(call.env, kv) {
			t.Errorf("env misses %s: %q", kv, call.env)
		}
	}
	if slices.Contains(call.env, "ROOTDIR=/wrong") {
		t.Errorf("ROOTDIR not replaced: %q", call.env)
	}
}

func TestRunTwiceIsIdempotent(t *testing.T) {
	root := release(t)
	env := map[string]string{"NODENAME": "node1", "ERLANG_COOKIE": "x"}
	for range 2 {
		l, _, _ := newLauncher(root, env)
		if err := l.run(nil); err != nil {
			t.Fatal(err)
		}
	}
	if got := readTestFile(t, filepath.Join(root, "etc", "vm.runtime.args")); got != "-name couchdb@node1\n-setcookie 'x'\n" {
		t.Errorf("vm.runtime.args %q", got)
	}
}

func TestRunAsRoot(t *testing.T) {
	root := release(t)
	var steps []string
	l, _, _ := newLauncher(root, map[string]string{"SINGLE_NODE": "1"})
	l.isRoot = true
	l.lchown = func(path string, uid, gid int) error {
		if uid != couchdbID || gid != couchdbID {
			t.Errorf("lchown %s %d:%d", path, uid, gid)
		}
		rel, _ := filepath.Rel(root, path)
		steps = append(steps, "chown "+rel)
		return nil
	}
	l.drop = func() error { steps = append(steps, "drop"); return nil }
	exec := l.exec
	l.exec = func(dir, argv0 string, argv, env []string) error {
		steps = append(steps, "exec")
		return exec(dir, argv0, argv, env)
	}
	if err := l.run(nil); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"chown data", "chown data/_dbs.couch", "chown etc", "chown etc/vm.runtime.args", "chown etc/default.d/00-single.ini", "chown var"} {
		if !slices.Contains(steps, want) {
			t.Errorf("missing %q in %q", want, steps)
		}
	}
	for _, s := range steps {
		if strings.HasPrefix(s, "chown lib") || strings.HasPrefix(s, "chown releases") || s == "chown ." {
			t.Errorf("unexpected %q", s)
		}
	}
	if n := len(steps); n < 2 || steps[n-2] != "drop" || steps[n-1] != "exec" {
		t.Errorf("drop must come right before exec: %q", steps)
	}
}

func TestRunAsRootSkipsReadOnlyMounts(t *testing.T) {
	root := release(t)
	readOnly := filepath.Join(root, "etc", "local.d")
	l, _, stderr := newLauncher(root, nil)
	l.isRoot = true
	l.drop = func() error { return nil }
	l.lchown = func(path string, _, _ int) error {
		if path == readOnly {
			return &fs.PathError{Op: "lchown", Path: path, Err: syscall.EROFS}
		}
		return nil
	}
	if err := l.run(nil); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stderr.String(), readOnly+" is read-only") {
		t.Errorf("stderr %q", stderr.String())
	}
}

func TestRunAsRootFailsOnChownError(t *testing.T) {
	root := release(t)
	l, call, _ := newLauncher(root, nil)
	l.isRoot = true
	l.lchown = func(path string, _, _ int) error {
		return &fs.PathError{Op: "lchown", Path: path, Err: syscall.EPERM}
	}
	if err := l.run(nil); err == nil {
		t.Fatal("no error")
	}
	if call.argv0 != "" {
		t.Error("exec called")
	}
}

func TestWriteFileReplacesSymlink(t *testing.T) {
	root := release(t)
	target := filepath.Join(t.TempDir(), "passwd")
	writeTestFile(t, target, "root:x:0:0\n")
	link := filepath.Join(root, "etc", "default.d", "99-creds.ini")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	l, _, _ := newLauncher(root, map[string]string{"COUCHDB_USER": "a", "COUCHDB_PASSWORD": "b"})
	if err := l.run(nil); err != nil {
		t.Fatal(err)
	}
	if got := readTestFile(t, target); got != "root:x:0:0\n" {
		t.Errorf("link target changed: %q", got)
	}
	fi, err := os.Lstat(link)
	if err != nil {
		t.Fatal(err)
	}
	if !fi.Mode().IsRegular() {
		t.Errorf("%s is %v, want a regular file", link, fi.Mode())
	}
}

func TestRunRefusesSymlinkedDefaultDir(t *testing.T) {
	root := release(t)
	defaultDir := filepath.Join(root, "etc", "default.d")
	if err := os.Remove(defaultDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(t.TempDir(), defaultDir); err != nil {
		t.Fatal(err)
	}
	l, call, _ := newLauncher(root, nil)
	if err := l.run(nil); err == nil {
		t.Fatal("no error")
	}
	if call.argv0 != "" {
		t.Error("exec called")
	}
}

func TestRunCreatesMissingDefaultDir(t *testing.T) {
	root := release(t)
	if err := os.Remove(filepath.Join(root, "etc", "default.d")); err != nil {
		t.Fatal(err)
	}
	l, _, _ := newLauncher(root, nil)
	if err := l.run(nil); err != nil {
		t.Fatal(err)
	}
	readTestFile(t, filepath.Join(root, "etc", "default.d", "10-logging.ini"))
}

func TestRunFailsWithoutRelease(t *testing.T) {
	l, call, _ := newLauncher(t.TempDir(), nil)
	if err := l.run(nil); err == nil {
		t.Fatal("no error")
	}
	if call.argv0 != "" {
		t.Error("exec called")
	}
}

func TestSetenv(t *testing.T) {
	got := setenv([]string{"A=1", "AB=2", "A=3"}, "A", "4")
	if want := []string{"AB=2", "A=4"}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
}
