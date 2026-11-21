package fixture

// Config is logic outside the boundary — the drive never calls Valid, and the ledger does not list it.
type Config struct{ Realm string }

// Valid never runs in the drive.
func (c Config) Valid() bool { return c.Realm != "" }
