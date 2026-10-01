package p.auth;

// class Fake {} — 주석 속 선언은 클래스가 아니다
public class AuthClient {
  private final String s = "class Inside { new Object() { }";
  private final Class<?> self = AuthClient.class;

  void run() {
    Runnable r = () -> {};
    r.run();
  }
}
