# pom reactor fixture

Models a real Maven multi-module layout: the parent pom declares the
`<properties>` entry but no `<dependency>`, and the child pom declares the
`<dependency>` referencing that property but no property of its own. A
single-file (non-reactor) parser cannot resolve this.

<!-- doc-guard: kind=dep source=pom-reactor/pom.xml min=1 -->

| 이름 | 좌표 | 버전 |
|---|---|---|
| Widget | `org.example:widget` | 2.0.0 |
