package fixture

// Config is logic — the unit gate measures it, not the integration report.
type Config struct{ Realm string }

// Valid runs.
func (c Config) Valid() bool { return c.Realm != "" }
