// healthcheck is the container healthcheck of the CouchDB image. The image has
// no bash and no coreutils, so Docker, osemctl and Kubernetes start this static
// binary directly.
//
// Usage: healthcheck --couchdb
//
// --couchdb: TCP connect to the CouchDB HTTP port 5984.
//
// Exit code 0 = healthy, 1 = unhealthy or usage error (Docker reserves 2).
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

// couchdbAddr is a variable so that the tests can set a local listener.
var couchdbAddr = "127.0.0.1:5984"

const timeout = 3 * time.Second

func run(args []string, out io.Writer) int {
	if len(args) != 1 || args[0] != "--couchdb" {
		fmt.Fprintln(out, "usage: healthcheck --couchdb")
		return 1
	}
	conn, err := net.DialTimeout("tcp", couchdbAddr, timeout)
	if err != nil {
		fmt.Fprintln(out, err)
		return 1
	}
	conn.Close()
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout))
}
