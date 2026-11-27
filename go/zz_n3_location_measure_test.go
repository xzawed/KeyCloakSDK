// measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
//
// What id does AdminClient.Users.Create return when the 201's Location carries a byte that is not visible ASCII? A raw TCP
// server answers the token grant with a token and the create with 201 +
// `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd` (Latin-1
// obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE), what
// net/http hands back as the header (CLIENT), and what the SDK returns (ID).
//
// Run: N3_OUT=<file> go -C go test -run TestZzN3LocationMeasure -count=1 .
package keycloak

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"

	"github.com/Nerzal/gocloak/v13"
)

const zzN3Users = "/admin/realms/it-realm/users"

type zzN3Server struct {
	ln       net.Listener
	mu       sync.Mutex
	location []byte
	seen     []string
}

func (s *zzN3Server) base() string { return "http://" + s.ln.Addr().String() }

func (s *zzN3Server) serve() {
	for {
		conn, err := s.ln.Accept()
		if err != nil {
			return
		}
		go s.handle(conn)
	}
}

// handle reads one request (head and a Content-Length or chunked body), answers it and closes.
func (s *zzN3Server) handle(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		return
	}
	parts := strings.Fields(line)
	if len(parts) < 2 {
		return
	}
	method, path := parts[0], parts[1]
	length, chunked := 0, false
	for {
		h, err := r.ReadString('\n')
		if err != nil {
			return
		}
		h = strings.TrimRight(h, "\r\n")
		if h == "" {
			break
		}
		name, value, _ := strings.Cut(h, ":")
		switch strings.ToLower(strings.TrimSpace(name)) {
		case "content-length":
			length, _ = strconv.Atoi(strings.TrimSpace(value))
		case "transfer-encoding":
			chunked = strings.Contains(strings.ToLower(value), "chunked")
		}
	}
	if chunked {
		for {
			sizeLine, err := r.ReadString('\n')
			if err != nil {
				return
			}
			size, _ := strconv.ParseInt(strings.TrimSpace(strings.Split(sizeLine, ";")[0]), 16, 64)
			if _, err := io.CopyN(io.Discard, r, size+2); err != nil {
				return
			}
			if size == 0 {
				break
			}
		}
	} else if length > 0 {
		if _, err := io.CopyN(io.Discard, r, int64(length)); err != nil {
			return
		}
	}
	s.mu.Lock()
	s.seen = append(s.seen, method+" "+path)
	location := s.location
	s.mu.Unlock()
	var answer []byte
	switch {
	case strings.HasSuffix(path, "/protocol/openid-connect/token"):
		body := `{"access_token":"at-n3","token_type":"Bearer","expires_in":300}`
		answer = []byte(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body))
	case method == "POST" && strings.TrimSuffix(path, "/") == zzN3Users:
		answer = append(append([]byte("HTTP/1.1 201 Created\r\nLocation: "), location...), []byte("\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")...)
	default:
		answer = []byte("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	}
	_, _ = conn.Write(answer)
}

func zzN3Hex(b []byte) string {
	out := make([]string, len(b))
	for i, x := range b {
		out[i] = fmt.Sprintf("%02X", x)
	}
	return strings.Join(out, " ")
}

// zzN3Show prints a Go string with non-printable-ASCII bytes escaped, its bytes, and its code points when it is UTF-8.
func zzN3Show(s string) string {
	var esc strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x20 && s[i] < 0x7F {
			esc.WriteByte(s[i])
		} else {
			fmt.Fprintf(&esc, `\x%02X`, s[i])
		}
	}
	out := fmt.Sprintf("\"%s\" bytes=[%s]", esc.String(), zzN3Hex([]byte(s)))
	if utf8.ValidString(s) {
		cps := []string{}
		for _, r := range s {
			cps = append(cps, fmt.Sprintf("U+%04X", r))
		}
		return out + " utf8_cps=[" + strings.Join(cps, ",") + "]"
	}
	return out + " utf8_valid=false"
}

func zzN3Tail(s string) string { return s[strings.LastIndex(s, "/")+1:] }

func TestZzN3LocationMeasure(t *testing.T) {
	outPath := os.Getenv("N3_OUT")
	if outPath == "" {
		t.Skip("measurement only — set N3_OUT")
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &zzN3Server{ln: ln}
	go srv.serve()
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	// Library versions: `go -C go list -m github.com/Nerzal/gocloak/v13 github.com/go-resty/resty/v2` (a test binary's
	// debug.ReadBuildInfo carries no deps).
	out := []string{
		fmt.Sprintf("ENV|go=%s|create=AdminClient.Users.Create", runtime.Version()),
		"HEADER|sdk|lane|case|field|value",
	}
	cases := []struct {
		name string
		id   []byte
	}{
		{"ascii-control", []byte("abc")},
		{"latin1-0xE9", []byte{'a', 'b', 0xE9, 'c', 'd'}},
		{"utf8-0xC3A9", []byte{'a', 'b', 0xC3, 0xA9, 'c', 'd'}},
	}
	for _, c := range cases {
		prefix := []byte(srv.base() + zzN3Users + "/")
		location := append(append([]byte{}, prefix...), c.id...)
		srv.mu.Lock()
		srv.location = location
		srv.mu.Unlock()

		// WIRE — the bytes a raw socket reads.
		probe, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(probe, "POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", zzN3Users, port)
		raw, _ := io.ReadAll(probe)
		probe.Close()
		var got []byte
		for _, l := range bytes.Split(raw, []byte("\r\n")) {
			if v, ok := bytes.CutPrefix(l, []byte("Location: ")); ok {
				got = v
			}
		}
		out = append(out, fmt.Sprintf("WIRE|go|-|%s|location=<base>/admin/realms/it-realm/users/+[%s]|raw_socket_read_equals_sent=%t|id_bytes_on_wire=%s",
			c.name, zzN3Hex(c.id), bytes.Equal(got, location), zzN3Hex(bytes.TrimPrefix(got, prefix))))

		// CLIENT — what net/http hands back.
		client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
		resp, err := client.Post(srv.base()+zzN3Users, "application/json", strings.NewReader("{}"))
		if err != nil {
			out = append(out, fmt.Sprintf("CLIENT|go|net/http|%s|error %v", c.name, err))
		} else {
			resp.Body.Close()
			out = append(out, fmt.Sprintf("CLIENT|go|net/http|%s|status=%d|Header.Get(\"Location\").after_last_slash=%s", c.name, resp.StatusCode, zzN3Show(zzN3Tail(resp.Header.Get("Location")))))
		}

		srv.mu.Lock()
		srv.seen = nil
		srv.mu.Unlock()
		result := func() string {
			kc, err := New(Config{ServerURL: srv.base(), Realm: "it-realm", ClientID: "it-client", ClientSecret: "dummy-secret"})
			if err != nil {
				return fmt.Sprintf("Err(New: %T: %v)", err, err)
			}
			defer kc.Close()
			ctx := context.Background()
			admin, err := kc.Admin(ctx)
			if err != nil {
				return fmt.Sprintf("Err(Admin: %T: %v)", err, err)
			}
			id, err := admin.Users.Create(ctx, gocloak.User{Username: gocloak.StringP("n3-user")})
			if err != nil {
				return fmt.Sprintf("Err(%T: %v)", err, err)
			}
			return "Ok(" + zzN3Show(id) + ")"
		}()
		srv.mu.Lock()
		seen := strings.Join(srv.seen, ",")
		srv.mu.Unlock()
		out = append(out, fmt.Sprintf("ID|go|AdminClient.Users.Create|%s|%s|requests=%s", c.name, strings.ReplaceAll(result, "|", "/"), seen))
	}
	if err := os.WriteFile(outPath, []byte(strings.Join(out, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}
