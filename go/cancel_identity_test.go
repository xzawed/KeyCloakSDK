package keycloak

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// 소비자는 errors.Is(err, context.DeadlineExceeded) 로 「시간이 다 됐다」를 가른다 — cause.go 의 scrubCause 주석이 그것을 약속한다.
// 그 정체가 교환 **도중**(머리를 받은 뒤 본문을 읽다가)에 기한이 오면 사라졌다: x/oauth2 는 본문 읽기 오류를 %v 로
// (internal/token.go), gocloak 은 요청 오류 전부를 APIError.Message 문자열로(client.go checkForError) 납작하게 만든다.
// 2026-10-27 실측(본문 64 B 뒤 멈춘 IdP · 호출자 기한 300 ms 와 SDK 읽기 타임아웃 5 s): 그랜트 셋과 admin 자원 호출이 거짓,
// introspect·Validate 는 참. 요청 전에 이미 취소된 호출은 TestScrubKeepsBelowHTTPErrorIdentity 가 잰다.

// ciSilent 는 요청을 받고 아무것도 답하지 않는다 — 머리 전의 기다림.
func ciSilent() rbReply {
	return func(net.Conn, *atomic.Int64) bool {
		time.Sleep(20 * time.Second)
		return false
	}
}

// ciDeadline 은 기한 하나다 — 호출자의 것(ctx) 또는 SDK 의 읽기 타임아웃(Config.ReadTimeout).
type ciDeadline struct {
	name     string
	ctx      func() (context.Context, context.CancelFunc)
	readTOms int64
}

func ciDeadlines() []ciDeadline {
	return []ciDeadline{
		{"호출자 기한", func() (context.Context, context.CancelFunc) {
			return context.WithTimeout(context.Background(), 300*time.Millisecond)
		}, 5000},
		{"SDK 읽기 타임아웃", func() (context.Context, context.CancelFunc) {
			return context.WithCancel(context.Background())
		}, 300},
	}
}

// ciShape 는 IdP 가 멈추는 자리다.
type ciShape struct {
	name    string
	midBody bool
	reply   rbReply
}

func ciShapes() []ciShape {
	return []ciShape{
		{"머리 전", false, ciSilent()},
		{"본문 64 B 뒤", true, rbStalled("200 OK", rbTyped, 64)},
	}
}

// ciCheck 는 오류가 기한의 정체와 그 레인의 SDK 타입을 함께 지니는지, 그리고 호출이 기다리지 않았는지 본다.
func ciCheck(t *testing.T, what string, err error, wantType string, elapsed time.Duration) {
	t.Helper()
	if elapsed > 3*time.Second {
		t.Errorf("%s: %d ms 를 기다렸다 — 기한이 교환을 끝내지 못했다", what, elapsed.Milliseconds())
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("%s: errors.Is(err, context.DeadlineExceeded) 가 거짓이다 — %T: %v", what, err, err)
	}
	if got := fmt.Sprintf("%T", err); got != wantType {
		t.Errorf("%s: %s 여야 하는데 %s 다", what, wantType, got)
	}
}

// TestDeadlineDuringTheExchange_keepsItsIdentity — 인증 레인 여섯(그랜트 셋 · admin 로그인 · introspect · logout). 타입은 레인의
// 계약 그대로다(README v1.2.3 노트 · causeWantKind — 그랜트는 *AuthError, 나머지는 *TransportError).
func TestDeadlineDuringTheExchange_keepsItsIdentity(t *testing.T) {
	want := map[string]string{
		callCC: "*keycloak.AuthError", callExchange: "*keycloak.AuthError", callRefresh: "*keycloak.AuthError",
		callAdmin: "*keycloak.TransportError", callIntrospect: "*keycloak.TransportError", callLogout: "*keycloak.TransportError",
	}
	for _, d := range ciDeadlines() {
		for _, sh := range ciShapes() {
			for _, call := range []string{callCC, callExchange, callRefresh, callAdmin, callIntrospect, callLogout} {
				t.Run(d.name+"/"+sh.name+"/"+call, func(t *testing.T) {
					t.Parallel()
					s := newRBServer(t, nil, func(string, string) rbReply { return sh.reply })
					c, err := New(Config{ServerURL: s.url("http"), Realm: "r", ClientID: "c", ClientSecret: "cs-in",
						ConnectTimeout: 5000, ReadTimeout: d.readTOms})
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() { _ = c.Close() })
					ctx, cancel := d.ctx()
					defer cancel()
					start := time.Now()
					err = causeRun(ctx, c, call)
					ciCheck(t, call, err, want[call], time.Since(start))
				})
			}
		}
	}
}

// ciAdminOp 는 admin 파사드 호출 하나다. 쓰기는 2xx 본문을 읽지 않으므로(adminbody.go) 본문 중간의 멈춤은 읽기에서만 잰다.
type ciAdminOp struct {
	name  string
	reads bool
	do    func(context.Context, *AdminClient) error
}

func ciAdminOps() []ciAdminOp {
	return []ciAdminOp{
		{"Users.Get", true, func(ctx context.Context, a *AdminClient) error { _, err := a.Users.Get(ctx, "abc"); return err }},
		{"Users.Search", true, func(ctx context.Context, a *AdminClient) error {
			_, err := a.Users.Search(ctx, "", 0, 10)
			return err
		}},
		{"Users.Create", false, func(ctx context.Context, a *AdminClient) error {
			_, err := a.Users.Create(ctx, rbUserRep())
			return err
		}},
		{"Users.Update", false, func(ctx context.Context, a *AdminClient) error { return a.Users.Update(ctx, "abc", rbUserRep()) }},
		{"Users.Delete", false, func(ctx context.Context, a *AdminClient) error { return a.Users.Delete(ctx, "abc") }},
	}
}

// TestAdminDeadlineDuringTheExchange_keepsItsIdentity — admin 자원 호출(토큰은 네트워크 없이 온다 — rbToken).
func TestAdminDeadlineDuringTheExchange_keepsItsIdentity(t *testing.T) {
	for _, d := range ciDeadlines() {
		for _, sh := range ciShapes() {
			for _, op := range ciAdminOps() {
				if sh.midBody && !op.reads {
					continue
				}
				t.Run(d.name+"/"+sh.name+"/"+op.name, func(t *testing.T) {
					t.Parallel()
					s := newRBServer(t, nil, func(string, string) rbReply { return sh.reply })
					a := rbAdmin(t, s, nil, time.Duration(d.readTOms)*time.Millisecond)
					ctx, cancel := d.ctx()
					defer cancel()
					start := time.Now()
					err := op.do(ctx, a)
					ciCheck(t, op.name, err, "*keycloak.TransportError", time.Since(start))
				})
			}
		}
	}
}

// TestAdminCancelledBeforeTheRequest_keepsItsIdentity — 이미 취소된 ctx 로 부른 admin 자원 호출은 서버에 닿지 않고
// errors.Is(err, context.Canceled) 다(인증 레인의 같은 칸은 TestScrubKeepsBelowHTTPErrorIdentity).
func TestAdminCancelledBeforeTheRequest_keepsItsIdentity(t *testing.T) {
	for _, op := range ciAdminOps() {
		t.Run(op.name, func(t *testing.T) {
			s := newRBServer(t, nil, func(string, string) rbReply {
				t.Error("취소된 요청이 서버에 닿았다")
				return ciSilent()
			})
			a := rbAdmin(t, s, nil, 5*time.Second)
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			err := op.do(ctx, a)
			if !errors.Is(err, context.Canceled) {
				t.Errorf("%s: errors.Is(err, context.Canceled) 가 거짓이다 — %T: %v", op.name, err, err)
			}
			var te *TransportError
			if !errors.As(err, &te) {
				t.Errorf("%s: *keycloak.TransportError 여야 하는데 %T 다", op.name, err)
			}
		})
	}
}
