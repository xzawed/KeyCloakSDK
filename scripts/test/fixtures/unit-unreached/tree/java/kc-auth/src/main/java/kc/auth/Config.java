package kc.auth;

/** Outside the boundary — the unit gate measures it. A ledger entry naming this file names a file outside the boundary. */
public final class Config {
  private Config() {}

  public static boolean valid(String realm) {
    return !realm.isEmpty();
  }
}
