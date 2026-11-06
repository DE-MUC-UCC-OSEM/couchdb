package main

import (
	"io"
	"net"
	"testing"
)

func setAddr(t *testing.T, addr string) {
	old := couchdbAddr
	couchdbAddr = addr
	t.Cleanup(func() { couchdbAddr = old })
}

func TestCouchdbReachable(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	setAddr(t, ln.Addr().String())
	if code := run([]string{"--couchdb"}, io.Discard); code != 0 {
		t.Errorf("exit code %d, want 0", code)
	}
}

func TestCouchdbUnreachable(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	setAddr(t, addr)
	if code := run([]string{"--couchdb"}, io.Discard); code != 1 {
		t.Errorf("exit code %d, want 1", code)
	}
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{nil, {"--other"}, {"--couchdb", "--couchdb"}} {
		if code := run(args, io.Discard); code != 1 {
			t.Errorf("args %v: exit code %d, want 1", args, code)
		}
	}
}
