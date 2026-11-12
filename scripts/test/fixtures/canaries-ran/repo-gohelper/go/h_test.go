package x

import "testing"

// 서브테스트를 같은 파일의 도우미가 연다 — bearer 표의 `grammarInjected(t, …)` 꼴.
func grammarCases(t *testing.T, call func()) {
	for _, id := range []string{"plain", "nbsp"} {
		t.Run(id, func(t *testing.T) { call() })
	}
}

func TestViaHelper(t *testing.T) {
	grammarCases(t, func() {})
}
