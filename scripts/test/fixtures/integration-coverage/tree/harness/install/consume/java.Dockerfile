# 픽스처 — 실제 harness/install/consume/java.Dockerfile 의 꼴(빌드 맥락 = 트리 루트). 장부의 하네스 소유 판정이 읽는다.
FROM maven:3.9-eclipse-temurin-21-alpine AS app
WORKDIR /work
COPY harness/install/consume/java-quickstart-pom.xml ./quickstart/pom.xml
COPY java/kc-examples/src/main/java/kc ./quickstart/src/main/java/kc
COPY harness/install/consume/java-run.sh ./run.sh
CMD ["sh", "/work/run.sh"]
