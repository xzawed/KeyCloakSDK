package kc.auth;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.Supplier;

/** Unit-unreached ledger fixture — the boundary class (java/pom.xml excludes it from the unit gate). The unit drive is DriveTest. */
public final class AuthClient {
  private final String base;

  public AuthClient(String base) {
    this.base = base;
  }

  /** The unit drive reaches all of it — not in the ledger. */
  public String realm() {
    return base;
  }

  /** A failure branch on its own line — the drive never sends a blank code (a missed line and a missed branch). */
  public String exchange(String code) {
    if (code.isBlank()) {
      throw new IllegalStateException("blank code");
    }
    return code.toUpperCase();
  }

  /** A failure branch on a line the happy path runs (a conditional) — the line runs, one branch is missed. */
  public String pick(String v) {
    return v != null ? v : "none";
  }

  /** A branch inside a lambda — the drive never passes null. The branch is the lambda method's; the key is the source method. */
  public String later(String v) {
    return describe(() -> v == null ? "none" : v);
  }

  /** An anonymous class — its compare folds into sorted (javap's EnclosingMethod); the drive never sorts a null. */
  public List<String> sorted(List<String> in) {
    List<String> copy = new ArrayList<>(in);
    copy.sort(new Comparator<String>() {
      @Override
      public int compare(String a, String b) {
        if (a == null) {
          return -1;
        }
        return b.compareTo(a);
      }
    });
    return copy;
  }

  /** Overload A — the drive calls it. */
  public String token(String user) {
    return base + "/" + user;
  }

  /** Overload B — the drive never calls it; the key carries its parameters. */
  public String token(String user, int ttl) {
    return base + "/" + user + "?ttl=" + ttl;
  }

  /** The unit drive never calls it — DriveIT does, outside the unit run. */
  public String logoutUrl() {
    return base + "/logout";
  }

  private static String describe(Supplier<String> s) {
    return s.get();
  }

  /** A named nested class — its own type; the drive never asks for an empty value. */
  public static final class Token {
    private final String value;

    public Token(String value) {
      this.value = value;
    }

    public String value() {
      return value.isEmpty() ? "-" : value;
    }
  }
}
