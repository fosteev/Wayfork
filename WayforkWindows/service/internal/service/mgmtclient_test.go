package service

import (
	"bufio"
	"context"
	"net"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestManagementClientAuthenticatesAndStreamsLines(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	received := make(chan string, 8)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		// The prompt arrives in two pieces and without a newline, like the real thing.
		conn.Write([]byte("ENTER PA"))
		time.Sleep(20 * time.Millisecond)
		conn.Write([]byte("SSWORD:"))
		reader := bufio.NewReader(conn)
		password, _ := reader.ReadString('\n')
		received <- strings.TrimSpace(password)
		conn.Write([]byte("SUCCESS: password is correct\r\n>INFO:OpenVPN Management Interface Version 5\r\n"))
		command, _ := reader.ReadString('\n')
		received <- strings.TrimSpace(command)
		conn.Write([]byte("SUCCESS: state on succeeded\r\n>HOLD:Waiting"))
	}()

	var mu sync.Mutex
	var lines []string
	closed := make(chan error, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := ConnectManagement(ctx, listener.Addr().String(), "s3cret", ManagementHandlers{
		OnLine: func(line string) {
			mu.Lock()
			lines = append(lines, line)
			mu.Unlock()
		},
		OnClose: func(err error) { closed <- err },
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := <-received; got != "s3cret" {
		t.Errorf("password sent = %q", got)
	}
	if err := client.Send("state on"); err != nil {
		t.Fatal(err)
	}
	if got := <-received; got != "state on" {
		t.Errorf("command received = %q", got)
	}
	select {
	case <-closed:
	case <-ctx.Done():
		t.Fatal("no close")
	}
	mu.Lock()
	defer mu.Unlock()
	want := []string{">INFO:OpenVPN Management Interface Version 5", "SUCCESS: state on succeeded", ">HOLD:Waiting"}
	if !slices.Equal(lines, want) {
		t.Errorf("lines = %q, want %q", lines, want)
	}
	if err := client.Send("late"); err == nil {
		t.Error("sends after close must fail")
	}
}

func TestManagementClientRejectsBadPasswordAndRetriesDial(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	// Nothing listens yet: the dial retries until the port opens.
	go func() {
		time.Sleep(150 * time.Millisecond)
		late, err := net.Listen("tcp4", address)
		if err != nil {
			return
		}
		defer late.Close()
		conn, err := late.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.Write([]byte("ENTER PASSWORD:"))
		bufio.NewReader(conn).ReadString('\n')
		conn.Write([]byte("ERROR: bad password\r\n"))
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := ConnectManagement(ctx, address, "wrong", ManagementHandlers{}); err == nil || !strings.Contains(err.Error(), "bad password") {
		t.Errorf("err = %v", err)
	}
	// A dead port fails when the context ends.
	short, cancelShort := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancelShort()
	if _, err := ConnectManagement(short, address, "x", ManagementHandlers{}); err == nil {
		t.Error("a dead port must fail")
	}
}
