package kc.examples;

/** Fixture example — its module is jacoco.skip, so the derivation forces it into the boundary; no test runs it. */
public final class QuickStart {
  private QuickStart() {}

  public static void main(String[] args) {
    System.out.println(env("KC_URL", "http://localhost:8080"));
  }

  static String env(String key, String fallback) {
    String v = System.getenv(key);
    return v == null ? fallback : v;
  }
}
