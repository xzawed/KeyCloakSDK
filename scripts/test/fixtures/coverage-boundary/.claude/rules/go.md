# go (fixture)

- Coverage: `go test ./... -coverprofile=cover.out`, then drop the boundary with `grep -vE '/(auth|admin|admin_users)\.go:'` and read `go tool cover -func`.
