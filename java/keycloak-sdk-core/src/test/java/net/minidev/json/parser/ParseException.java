package net.minidev.json.parser;

/**
 * 테스트 전용 대역 — core 는 json-smart 에 의존하지 않아서, {@code KeycloakSdkException} 이 **이름으로** 알아보는 응답
 * 파서 타입을 core 테스트 안에서 만들 길이 이것뿐이다. 실제 타입처럼 메시지에 입력을 인용한다. ⚠️ core 테스트
 * 클래스패스에 json-smart 가 들어오면 이 파일을 지워라(같은 이름이 둘이 된다).
 */
public class ParseException extends Exception {
  public ParseException(String message) {
    super(message);
  }
}
