package fixture

// UsersResource groups the user calls.
type UsersResource struct{ n int }

// Create runs.
func (r *UsersResource) Create(name string) int {
	r.n += len(name)
	return r.n
}

// Delete never runs.
func (r *UsersResource) Delete(id string) error {
	if id == "" {
		return nil
	}
	r.n--
	return nil
}

// first is generic and its signature spans lines.
func first[T any](
	xs []T,
) T {
	return xs[0]
}
