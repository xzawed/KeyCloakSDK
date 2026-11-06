package kc.auth;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.Supplier;
import java.util.function.UnaryOperator;

/** Fixture boundary class — every shape the java reader folds. */
public final class AuthClient {
  // 정적 초기화(<clinit>) — 클래스가 실리기만 해도 돈다. 상수가 아니라 실릴 때 계산된다.
  public static final String REALM = new String("kc");
  // 정적 람다(lambda$static$N) — 정적 초기화에 접힌다(값은 실릴 때 · 몸통은 불릴 때 돈다).
  private static final UnaryOperator<String> UPPER = s -> s.toUpperCase();

  private final String base;

  public AuthClient(String base) {
    this.base = base;
  }

  /** Runs — a lambda folds into it. */
  public List<String> names(List<String> raw) {
    List<String> out = new ArrayList<>();
    raw.forEach(n -> out.add(UPPER.apply(n)));
    return out;
  }

  /** Overload A — runs; its lambda is told from B's by the line ranges. */
  public String token(String user) {
    return describe(() -> base + "/" + user);
  }

  /** Overload B — never runs. */
  public String token(String user, int ttl) {
    return describe(() -> base + "/" + user + "?ttl=" + ttl);
  }

  /** Runs — an anonymous class folds into it (javap's EnclosingMethod). */
  public List<String> sorted(List<String> in) {
    List<String> copy = new ArrayList<>(in);
    copy.sort(new Comparator<String>() {
      @Override
      public int compare(String a, String b) {
        return b.compareTo(a);
      }
    });
    return copy;
  }

  /** Never runs. */
  public String unused() {
    return base.repeat(2);
  }

  private static String describe(Supplier<String> s) {
    return s.get();
  }

  /** A named member class — its own scope; its field lambda sits in both constructors (javac copies field initializers). */
  public static final class Token {
    private final Supplier<String> label = () -> "token";
    private final String value;

    public Token(String value) {
      this.value = value;
    }

    /** Never runs — the field lambda belongs to it as well. */
    public Token(char c) {
      this.value = String.valueOf(c);
    }

    public String value() {
      return value + "/" + label.get();
    }
  }

  /** A nested enum — javac adds $values() · values() · valueOf(); JaCoCo's filters decide which reach the data. */
  public enum Mode {
    PLAIN,
    MASKED
  }
}
