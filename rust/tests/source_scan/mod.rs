//! 소스 파생 — `rust/src/**/*.rs` 를 읽는 판독기 **하나**. `facade_dump.rs`(선언·바닥·변형·재노출)와
//! `hostile_path_matrix.rs`(공개 fn 과 그 시그니처)가 함께 쓴다 — 판독기를 둘로 만들지 않는다.
//!
//! 문자열·문자·주석을 걷어 낸 토큰 위에서 선언·impl·`pub use` 를 읽는다. `syn` 을 들이지 않는 대신
//! `facade_dump.rs` 의 `scanner_*` 와 `hostile_path_matrix.rs` 의 `fn_scanner_*` 가 이 판독기가 기대는
//! 모양을 고정한다.
//!
//! ⚠️ 두 시험 크레이트가 각자 쓰는 부분만 쓴다 — 한쪽에서 안 쓰는 항목이 `dead_code` 로 울지 않게 모듈
//! 전체에서 끈다(`tests/common` 관용).
#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub enum Tok {
    Id(String),
    P(char),
    Lit,
    Life,
}

pub fn is_ident_start(c: char) -> bool {
    c == '_' || c.is_alphabetic()
}
pub fn is_ident_char(c: char) -> bool {
    c == '_' || c.is_alphanumeric()
}
pub fn at(c: &[char], k: usize) -> char {
    c.get(k).copied().unwrap_or('\0')
}
pub fn find(c: &[char], from: usize, ch: char) -> usize {
    (from..c.len()).find(|&k| c[k] == ch).unwrap_or(c.len())
}
pub fn skip_ident(c: &[char], mut k: usize) -> usize {
    while k < c.len() && is_ident_char(c[k]) {
        k += 1;
    }
    k
}

pub fn lex(src: &str) -> Vec<Tok> {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let (next, tok) = lex_one(&c, i);
        out.extend(tok);
        i = next;
    }
    out
}

/// 토큰 하나(또는 공백·주석)를 읽고 다음 위치를 돌려준다.
pub fn lex_one(c: &[char], i: usize) -> (usize, Option<Tok>) {
    let ch = c[i];
    match ch {
        _ if ch.is_whitespace() => (i + 1, None),
        '/' if at(c, i + 1) == '/' => (find(c, i, '\n'), None),
        '/' if at(c, i + 1) == '*' => (skip_block_comment(c, i), None),
        '"' => (skip_str(c, i), Some(Tok::Lit)),
        '\'' => lex_quote(c, i),
        _ if is_ident_start(ch) => lex_word(c, i),
        _ if ch.is_ascii_digit() => (skip_number(c, i), Some(Tok::Lit)),
        _ => (i + 1, Some(Tok::P(ch))),
    }
}

/// 중첩되는 `/* … */`.
pub fn skip_block_comment(c: &[char], mut i: usize) -> usize {
    let mut depth = 0;
    while i < c.len() {
        if c[i] == '/' && at(c, i + 1) == '*' {
            depth += 1;
            i += 2;
        } else if c[i] == '*' && at(c, i + 1) == '/' {
            depth -= 1;
            i += 2;
            if depth == 0 {
                return i;
            }
        } else {
            i += 1;
        }
    }
    i
}

pub fn skip_str(c: &[char], mut k: usize) -> usize {
    k += 1; // 여는 따옴표
    while k < c.len() {
        match c[k] {
            '\\' => k += 2,
            '"' => return k + 1,
            _ => k += 1,
        }
    }
    k
}

/// 원시 문자열 몸통 — 같은 수의 `#` 가 붙은 닫는 따옴표까지.
pub fn skip_raw_str(c: &[char], mut k: usize, hashes: usize) -> usize {
    while k < c.len() && !(c[k] == '"' && (1..=hashes).all(|h| at(c, k + h) == '#')) {
        k += 1;
    }
    k + hashes + 1
}

pub fn skip_number(c: &[char], i: usize) -> usize {
    let alnum = |mut k: usize| {
        while k < c.len() && (c[k].is_ascii_alphanumeric() || c[k] == '_') {
            k += 1;
        }
        k
    };
    let k = alnum(i);
    if at(c, k) == '.' && at(c, k + 1).is_ascii_digit() {
        alnum(k + 1)
    } else {
        k
    }
}

/// `'x'`·`'\n'`·`'\u{..}'` 문자 리터럴, 아니면 `'a` 수명.
pub fn lex_quote(c: &[char], i: usize) -> (usize, Option<Tok>) {
    if at(c, i + 1) == '\\' {
        // 이스케이프된 한 글자(닫는 따옴표일 수도 있다)를 건너뛴 뒤 닫는 따옴표까지.
        (find(c, i + 3, '\'') + 1, Some(Tok::Lit))
    } else if at(c, i + 2) == '\'' {
        (i + 3, Some(Tok::Lit))
    } else {
        (skip_ident(c, i + 1), Some(Tok::Life))
    }
}

/// 식별자. 원시 문자열(`r#"…"#`)·바이트/C 문자열(`b"…"`)·바이트 문자(`b'x'`)·원시 식별자(`r#type`)
/// 접두사를 여기서 가른다.
pub fn lex_word(c: &[char], i: usize) -> (usize, Option<Tok>) {
    let end = skip_ident(c, i);
    let word: String = c[i..end].iter().collect();
    let hashes = c[end..].iter().take_while(|&&x| x == '#').count();
    match word.as_str() {
        "r" | "br" | "cr" if at(c, end + hashes) == '"' => {
            (skip_raw_str(c, end + hashes + 1, hashes), Some(Tok::Lit))
        }
        "b" | "c" if at(c, end) == '"' => (skip_str(c, end), Some(Tok::Lit)),
        "b" if at(c, end) == '\'' => (lex_quote(c, end).0, Some(Tok::Lit)),
        "r" if hashes == 1 && is_ident_start(at(c, end + 1)) => {
            let e = skip_ident(c, end + 1);
            (e, Some(Tok::Id(c[end + 1..e].iter().collect())))
        }
        _ => (end, Some(Tok::Id(word))),
    }
}

pub fn id(t: Option<&Tok>) -> Option<&str> {
    match t {
        Some(Tok::Id(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// `toks[open]` 의 여는 괄호와 짝인 닫는 괄호의 위치.
pub fn matching(toks: &[Tok], open: usize) -> usize {
    let (o, c) = match toks[open] {
        Tok::P('(') => ('(', ')'),
        Tok::P('[') => ('[', ']'),
        _ => ('{', '}'),
    };
    let mut depth = 0;
    for (k, t) in toks.iter().enumerate().skip(open) {
        if *t == Tok::P(o) {
            depth += 1;
        } else if *t == Tok::P(c) {
            depth -= 1;
            if depth == 0 {
                return k;
            }
        }
    }
    toks.len() - 1
}

/// 항목 하나를 통째로 건너뛴다 — `;` 로 끝나거나 `{ … }` 몸통의 끝까지.
pub fn skip_item(toks: &[Tok], mut k: usize) -> usize {
    let mut depth = 0;
    while k < toks.len() {
        match toks[k] {
            Tok::P('(' | '[') => depth += 1,
            Tok::P(')' | ']') => depth -= 1,
            Tok::P(';') if depth == 0 => return k + 1,
            Tok::P('{') if depth == 0 => return matching(toks, k) + 1,
            _ => {}
        }
        k += 1;
    }
    k
}

/// `->` 의 `>` 는 꺾쇠가 아니다.
pub fn closes_angle(toks: &[Tok], k: usize) -> bool {
    toks[k] == Tok::P('>') && (k == 0 || toks[k - 1] != Tok::P('-'))
}

/// `toks[k]` 가 `<` 이면 짝인 `>` 다음 위치, 아니면 `k`.
pub fn skip_angles(toks: &[Tok], mut k: usize) -> usize {
    if toks.get(k) != Some(&Tok::P('<')) {
        return k;
    }
    let mut angle = 0;
    while k < toks.len() {
        if toks[k] == Tok::P('<') {
            angle += 1;
        } else if closes_angle(toks, k) {
            angle -= 1;
            if angle == 0 {
                return k + 1;
            }
        }
        k += 1;
    }
    k
}

/// 꺾쇠 깊이 0 에 있는 마지막 식별자 — `std::fmt::Debug` → `Debug`, `Wrapper<T>` → `Wrapper`.
pub fn last_top_ident(toks: &[Tok]) -> Option<String> {
    let mut angle = 0i32;
    let mut last = None;
    for (k, t) in toks.iter().enumerate() {
        match t {
            Tok::P('<') => angle += 1,
            Tok::P('>') if closes_angle(toks, k) => angle -= 1,
            Tok::Id(s) if angle == 0 && !matches!(s.as_str(), "dyn" | "mut" | "impl") => {
                last = Some(s.clone())
            }
            _ => {}
        }
    }
    last
}

/// `impl` 뒤 머리를 읽어 `(트레이트 끝 이름, 대상 타입 끝 이름)` 을 낸다. 인자 위치의 `impl Trait`
/// 처럼 `for` 가 없거나 몸통 `{` 로 끝나지 않으면 사실이 아니다. 몸통은 건너뛰지 않는다(안의 선언도 읽는다).
pub fn impl_header(toks: &[Tok], k: usize) -> (usize, Option<(String, String)>) {
    let start = skip_angles(toks, k);
    let mut k = start;
    let (mut depth, mut angle, mut for_at) = (0i32, 0i32, None);
    while let Some(t) = toks.get(k) {
        match t {
            Tok::P('(' | '[') => depth += 1,
            Tok::P(')' | ']') if depth == 0 => break,
            Tok::P(')' | ']') => depth -= 1,
            Tok::P('<') => angle += 1,
            Tok::P('>') if closes_angle(toks, k) => angle -= 1,
            Tok::P('{' | ';') if depth == 0 => break,
            Tok::P(',' | '=') if depth == 0 && angle == 0 => break,
            Tok::Id(s) if s == "for" && depth == 0 && angle == 0 && for_at.is_none() => {
                for_at = Some(k)
            }
            _ => {}
        }
        k += 1;
    }
    let Some(f) = for_at.filter(|_| toks.get(k) == Some(&Tok::P('{'))) else {
        return (k, None);
    };
    let ty_end = toks[f + 1..k]
        .iter()
        .position(|t| *t == Tok::Id("where".into()))
        .map_or(k, |p| f + 1 + p);
    let fact = last_top_ident(&toks[start..f]).zip(last_top_ident(&toks[f + 1..ty_end]));
    (k, fact)
}

/// `use` 트리를 펴서 `(경로, 드러나는 이름)` 을 모은다 — `a::{b::C, D as E, *}`.
pub fn use_tree(
    toks: &[Tok],
    mut k: usize,
    prefix: &mut Vec<String>,
    out: &mut Vec<(Vec<String>, String)>,
) -> usize {
    let base = prefix.len();
    loop {
        match toks.get(k) {
            Some(Tok::Id(s)) if s != "as" => {
                prefix.push(s.clone());
                k += 1;
                if toks.get(k) == Some(&Tok::P(':')) && toks.get(k + 1) == Some(&Tok::P(':')) {
                    k += 2;
                    continue;
                }
                let name = if id(toks.get(k)) == Some("as") {
                    k += 2;
                    id(toks.get(k - 1)).unwrap_or("_").to_string()
                } else {
                    s.clone()
                };
                out.push((prefix.clone(), name));
                break;
            }
            Some(Tok::P('{')) => {
                k += 1;
                while toks.get(k).is_some_and(|t| *t != Tok::P('}')) {
                    k = use_tree(toks, k, prefix, out);
                    if toks.get(k) == Some(&Tok::P(',')) {
                        k += 1;
                    }
                }
                k += 1;
                break;
            }
            Some(Tok::P('*')) => {
                out.push((prefix.clone(), "*".into()));
                k += 1;
                break;
            }
            Some(Tok::P(':')) => k += 1,
            _ => break,
        }
    }
    prefix.truncate(base);
    k
}

/// `enum` 이름 뒤에서 몸통을 찾아 변형 이름을 모은다(변형 속성·페이로드는 건너뛴다).
pub fn enum_variants(toks: &[Tok], from: usize) -> Vec<String> {
    let open = (from..toks.len()).find(|&k| toks[k] == Tok::P('{'));
    let Some(open) = open else {
        return Vec::new();
    };
    let body = &toks[open + 1..matching(toks, open)];
    let mut out = Vec::new();
    let mut k = 0;
    while k < body.len() {
        while body.get(k) == Some(&Tok::P('#')) && body.get(k + 1) == Some(&Tok::P('[')) {
            k = matching(body, k + 1) + 1;
        }
        out.extend(id(body.get(k)).map(str::to_string));
        let mut depth = 0i32;
        while k < body.len() {
            match body[k] {
                Tok::P('(' | '[' | '{') => depth += 1,
                Tok::P(')' | ']' | '}') => depth -= 1,
                Tok::P(',') if depth == 0 => break,
                _ => {}
            }
            k += 1;
        }
        k += 1;
    }
    out
}

/// `toks[i]` 에서 속성 하나를 읽는다 → `(바깥 속성의 몸통, 다음 위치)`. 안쪽 속성(`#![…]`)은 몸통 없이 건너뛴다.
pub fn attribute(toks: &[Tok], i: usize) -> Option<(Option<&[Tok]>, usize)> {
    if toks[i] != Tok::P('#') {
        return None;
    }
    let inner = toks.get(i + 1) == Some(&Tok::P('!'));
    let open = i + 1 + usize::from(inner);
    if toks.get(open) != Some(&Tok::P('[')) {
        return None;
    }
    let close = matching(toks, open);
    Some(((!inner).then(|| &toks[open + 1..close]), close + 1))
}

/// `pub` 을 읽어 `(키워드 위치, 크레이트 밖에서 이름 붙일 수 있는가)`. `pub(crate)` 등은 아니다.
pub fn visibility(toks: &[Tok], i: usize) -> (usize, bool) {
    if id(toks.get(i)) != Some("pub") {
        return (i, false);
    }
    if toks.get(i + 1) == Some(&Tok::P('(')) {
        (matching(toks, i + 1) + 1, false)
    } else {
        (i + 1, true)
    }
}

pub fn is_cfg_test(attr: &[Tok]) -> bool {
    id(attr.first()) == Some("cfg")
        && attr.contains(&Tok::Id("test".into()))
        && !attr.contains(&Tok::Id("not".into()))
}

/// 속성들의 `derive(…)`(+ `cfg_attr(…, derive(…))`) 이름 끝 조각.
pub fn derives(attrs: &[&[Tok]]) -> Vec<String> {
    let mut out = Vec::new();
    for a in attrs {
        for (k, t) in a.iter().enumerate() {
            if *t == Tok::Id("derive".into()) && a.get(k + 1) == Some(&Tok::P('(')) {
                let close = matching(a, k + 1);
                for seg in a[k + 2..close].split(|t| *t == Tok::P(',')) {
                    out.extend(last_top_ident(seg));
                }
            }
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Decl {
    pub file: String,
    pub public: bool,
    pub debug: bool,
    pub display: bool,
    /// 열거형이면 선언된 변형 이름(구조체는 비어 있다).
    pub variants: Vec<String>,
}

/// 소스에 선언된 fn 하나 — impl 메서드(고유·트레이트) · 트레이트 기본 메서드 · 자유 fn.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FnDecl {
    /// `T::m`(고유) · `<T as Tr>::m`(트레이트 impl) · `Tr::m`(트레이트 기본 메서드) · `모듈::f`(자유 fn).
    pub label: String,
    pub file: String,
    /// impl 대상 타입의 끝 이름(자유 fn·트레이트 기본 메서드는 `None`).
    pub owner: Option<String>,
    /// 트레이트 impl·트레이트 기본 메서드면 그 트레이트의 끝 이름.
    pub trait_name: Option<String>,
    pub name: String,
    /// `self` 를 받는가(`&self`·`&mut self`·`self`·`self: T`).
    pub receiver: bool,
    /// `(이름, 타입)` — `self` 를 뺀 선언 순서. 패턴 인자(`(a, b): T`)의 이름은 `_` 다.
    pub params: Vec<(String, String)>,
    pub ret: String,
    /// 몸통이 부르는 이름 — `.x(`·`::x(` 꼴(매크로 `x!(` 는 아니다).
    pub calls: BTreeSet<String>,
    /// 몸통이 있다(트레이트의 필수 메서드는 없다).
    pub has_body: bool,
    /// `pub`(고유·자유 fn) — `pub(crate)` 등은 아니다. 트레이트 impl 은 `resolve` 가 트레이트 가시성으로 채운다.
    pub vis_pub: bool,
    /// fn 몸통 안(지역 항목)에서 선언됐다 — 자유 fn 이면 밖에서 부를 수 없다.
    pub nested: bool,
}

#[derive(Debug, Default)]
pub struct Scan {
    pub decls: BTreeMap<String, Decl>,
    /// 루트가 재노출하는 foreign **타입** 이름 → 원 경로.
    pub foreign_reexports: BTreeMap<String, String>,
    /// 파생이 판독할 수 없어 사람이 봐야 하는 자리(글롭 재노출·같은 짧은 이름 둘·같은 라벨 둘).
    pub unreadable: Vec<String>,
    impls: Vec<(String, String)>,
    uses: Vec<(String, Vec<String>, String)>,
    local: BTreeSet<String>,
    /// 선언된 fn 전부(가시성 무관 — 공개 판정은 [`Scan::public_fns`]).
    pub fns: Vec<FnDecl>,
    /// SDK 가 선언한 트레이트 → `pub` 인가.
    pub traits: BTreeMap<String, bool>,
}

/// `(파일 줄기, 소스)` 목록에서 선언·바닥·변형·재노출·fn 을 파생한다.
pub fn scan(files: &[(String, String)]) -> Scan {
    let mut sc = Scan {
        local: ["crate", "self", "super"].map(String::from).into(),
        ..Scan::default()
    };
    for (stem, src) in files {
        sc.local.insert(stem.clone());
        let toks = lex(src);
        sc.file(stem, &toks);
        let module = if stem == "lib" {
            "crate"
        } else {
            stem.as_str()
        };
        sc.fn_items(stem, module, &toks, 0, toks.len(), false);
    }
    sc.resolve();
    sc
}

impl Scan {
    fn file(&mut self, stem: &str, toks: &[Tok]) {
        let mut attrs: Vec<&[Tok]> = Vec::new();
        let mut i = 0;
        while i < toks.len() {
            if let Some((attr, next)) = attribute(toks, i) {
                attrs.extend(attr);
                i = next;
                continue;
            }
            i = if attrs.iter().any(|a| is_cfg_test(a)) {
                skip_item(toks, i)
            } else {
                self.item(stem, toks, i, &attrs)
            };
            attrs.clear();
        }
    }

    /// 항목 머리 하나를 읽고 다음 위치를 돌려준다. 몸통은 건너뛰지 않는다(안의 선언도 읽는다).
    fn item(&mut self, stem: &str, toks: &[Tok], i: usize, attrs: &[&[Tok]]) -> usize {
        let (j, public) = visibility(toks, i);
        match id(toks.get(j)) {
            Some(kw @ ("struct" | "enum" | "union")) => {
                if let Some(name) = id(toks.get(j + 1)) {
                    let variants = if kw == "enum" {
                        enum_variants(toks, j + 2)
                    } else {
                        Vec::new()
                    };
                    self.declare(stem, name, public, &derives(attrs), variants);
                }
                j + 2
            }
            Some("impl") => {
                let (end, fact) = impl_header(toks, j + 1);
                self.impls.extend(fact);
                end
            }
            Some("use") if public => {
                let mut found = Vec::new();
                let end = use_tree(toks, j + 1, &mut Vec::new(), &mut found);
                self.uses
                    .extend(found.into_iter().map(|(p, n)| (stem.to_string(), p, n)));
                end
            }
            Some("mod") => {
                self.local.extend(id(toks.get(j + 1)).map(str::to_string));
                i + 1
            }
            _ => i + 1,
        }
    }

    fn declare(
        &mut self,
        stem: &str,
        name: &str,
        public: bool,
        derived: &[String],
        variants: Vec<String>,
    ) {
        // ⚠️ 대조는 짧은 이름으로 한다 — 같은 이름이 둘이면 하나가 찍힌 것으로 다른 하나가 통과한다.
        if let Some(prev) = self.decls.get(name) {
            self.unreadable.push(format!(
                "{name}: {} 와 {stem}.rs 에 같은 짧은 이름이 있다 — 대조가 둘을 구분할 수 없다",
                prev.file
            ));
        }
        let d = self.decls.entry(name.to_string()).or_default();
        d.file = format!("{stem}.rs");
        d.public |= public;
        // derive(Error) 는 std::error::Error 를 낳고, 그 상위 트레이트가 Debug + Display 다.
        d.debug |= derived.iter().any(|x| x == "Debug" || x == "Error");
        d.display |= derived.iter().any(|x| x == "Error");
        d.variants.extend(variants);
    }

    fn resolve(&mut self) {
        for (tr, ty) in std::mem::take(&mut self.impls) {
            if let Some(d) = self.decls.get_mut(&ty) {
                d.debug |= tr == "Debug" || tr == "Error";
                d.display |= tr == "Display" || tr == "Error";
            }
        }
        for (stem, p, name) in std::mem::take(&mut self.uses) {
            if p.first().is_some_and(|root| self.local.contains(root)) {
                continue;
            }
            if name == "*" {
                self.unreadable.push(format!(
                    "{stem}.rs: pub use {}::* — 글롭 재노출은 파생이 열거할 수 없다",
                    p.join("::")
                ));
            } else if name.starts_with(|c: char| c.is_ascii_uppercase()) {
                // 소문자는 모듈·함수·crate 다(러스트 명명 규약) — 타입이 아니므로 바닥이 없다.
                self.foreign_reexports.insert(name, p.join("::"));
            }
        }
        // 트레이트 impl 메서드는 가시성 키워드가 없다 — 트레이트가 공개면 공개다. SDK 가 선언하지 않은
        // 트레이트(std·하위 crate)는 공개로 본다(모르면 넓히는 쪽 — 좁히면 새 경로가 조용히 빠진다).
        for f in &mut self.fns {
            if f.owner.is_some()
                && let Some(tr) = &f.trait_name
            {
                f.vis_pub = self.traits.get(tr).copied().unwrap_or(true);
            }
        }
        let mut seen = BTreeMap::new();
        for f in &self.fns {
            if let Some(prev) = seen.insert(f.label.clone(), f.file.clone()) {
                self.unreadable.push(format!(
                    "{}: {prev} 와 {} 에 같은 라벨의 fn 이 있다 — 대조가 둘을 구분할 수 없다",
                    f.label, f.file
                ));
            }
        }
    }

    /// 크레이트 밖에서 부를 수 있는 fn — 규칙이지 이름 목록이 아니다.
    /// - impl 메서드: 대상이 SDK 가 `pub` 으로 선언한 타입이고, 메서드가 `pub`(고유) 이거나 트레이트가
    ///   공개(트레이트 impl)다. ⚠️ 대상이 SDK 타입이 아닌 impl(`impl KindStr for jsonwebtoken::…`)은 빠진다.
    /// - 트레이트 기본 메서드: 트레이트가 SDK 의 `pub` 트레이트다.
    /// - 자유 fn: `pub` 이고 fn 몸통 안이 아니다. ⚠️ 모듈 가시성은 따지지 않는다 — 비공개 모듈의 `pub fn` 도
    ///   `pub use` 로 드러날 수 있어서, 모르면 넓히는 쪽(대조 표가 요구하게)으로 둔다.
    pub fn public_fns(&self) -> Vec<&FnDecl> {
        self.fns
            .iter()
            .filter(|f| {
                f.vis_pub
                    && match &f.owner {
                        Some(ty) => self.decls.get(ty).is_some_and(|d| d.public),
                        None => !f.nested,
                    }
            })
            .collect()
    }

    /// 항목 목록 `toks[i..end]` 에서 fn 을 모은다 — 모듈 본문·impl 본문·fn 몸통(지역 항목) 모두.
    /// ⚠️ fn 몸통도 걷는다: 몸통 안의 `impl T { pub fn … }` 은 **크레이트 전역에서 보이는** 메서드다.
    fn fn_items(
        &mut self,
        stem: &str,
        module: &str,
        toks: &[Tok],
        mut i: usize,
        end: usize,
        nested: bool,
    ) {
        let mut test_only = false;
        while i < end {
            if let Some((attr, next)) = attribute(toks, i) {
                test_only |= attr.is_some_and(is_cfg_test);
                i = next;
                continue;
            }
            if std::mem::take(&mut test_only) {
                i = skip_item(toks, i).min(end);
                continue;
            }
            let (j, public) = visibility(toks, i);
            let j = skip_qualifiers(toks, j);
            i = match id(toks.get(j)) {
                Some("fn") => {
                    let (next, f) = self.fn_decl(stem, toks, j, end);
                    if let Some(mut f) = f {
                        f.label = format!("{module}::{}", f.name);
                        f.vis_pub = public;
                        f.nested = nested;
                        self.fns.push(f);
                    }
                    next
                }
                Some("impl") => self.impl_block(stem, toks, j, end),
                Some("trait") => self.trait_block(stem, toks, j, end, public),
                Some("mod") if toks.get(j + 2) == Some(&Tok::P('{')) => {
                    let close = matching(toks, j + 2);
                    let name = id(toks.get(j + 1)).unwrap_or("_");
                    let inner = format!("{module}::{name}");
                    self.fn_items(stem, &inner, toks, j + 3, close, nested);
                    close + 1
                }
                _ => {
                    // fn 몸통의 문장 매크로(`println!`·`assert!`)는 항목을 찍지 않는다 — 모듈 자리만 본다.
                    if !nested {
                        self.flag_item_macro(stem, toks, j, "모듈");
                    }
                    skip_item(toks, i).max(i + 1)
                }
            }
            .min(end);
        }
    }

    /// 항목 자리의 매크로 호출(`mint!();`·`a::b! { … }`)은 판독기가 펼 수 없다 — 그것이 찍어 내는 fn 은 선언
    /// 집합 밖으로 조용히 빠진다(Grok 레그 실측: impl 안의 `mint!()` 가 만든 `pub async fn` 이 SILENT).
    /// 그래서 판독 불가로 떨어뜨린다(닫힌 쪽). `macro_rules!` 정의는 호출이 아니다.
    fn flag_item_macro(&mut self, stem: &str, toks: &[Tok], i: usize, place: &str) {
        let mut k = i;
        let mut path = Vec::new();
        while let Some(seg) = id(toks.get(k)) {
            path.push(seg);
            if toks.get(k + 1) == Some(&Tok::P(':')) && toks.get(k + 2) == Some(&Tok::P(':')) {
                k += 3;
            } else {
                k += 1;
                break;
            }
        }
        if !path.is_empty() && path != ["macro_rules"] && toks.get(k) == Some(&Tok::P('!')) {
            self.unreadable.push(format!(
                "{stem}.rs: {place} 자리의 매크로 {}! — 그것이 찍어 내는 fn 은 판독기가 열거할 수 없다(펼쳐 쓰거나 판독기를 넓혀라)",
                path.join("::")
            ));
        }
    }

    /// `toks[j]` 가 `fn` — 시그니처를 읽고, 몸통이 있으면 부르는 이름을 모으고 지역 항목을 걷는다.
    fn fn_decl(
        &mut self,
        stem: &str,
        toks: &[Tok],
        j: usize,
        end: usize,
    ) -> (usize, Option<FnDecl>) {
        let Some(name) = id(toks.get(j + 1)) else {
            return (j + 1, None);
        };
        let open = skip_angles(toks, j + 2);
        if toks.get(open) != Some(&Tok::P('(')) {
            return (j + 2, None);
        }
        let close = matching(toks, open);
        let mut f = FnDecl {
            file: format!("{stem}.rs"),
            name: name.to_string(),
            ..FnDecl::default()
        };
        for seg in split_top(&toks[open + 1..close]) {
            match param(seg) {
                None => f.receiver = true,
                Some(p) => f.params.push(p),
            }
        }
        // 반환 타입 — `->` 뒤, 몸통 `{`·`;`·`where` 앞(꺾쇠·괄호 깊이 0).
        let mut k = close + 1;
        let (mut angle, mut depth) = (0i32, 0i32);
        let mut ret_start = None;
        while k < end {
            match &toks[k] {
                Tok::P('-') if toks.get(k + 1) == Some(&Tok::P('>')) && ret_start.is_none() => {
                    ret_start = Some(k + 2);
                    k += 2;
                    continue;
                }
                Tok::P('<') => angle += 1,
                Tok::P('>') if closes_angle(toks, k) => angle -= 1,
                Tok::P('(' | '[') => depth += 1,
                Tok::P(')' | ']') => depth -= 1,
                Tok::P('{' | ';') if angle == 0 && depth == 0 => break,
                Tok::Id(w) if w == "where" && angle == 0 && depth == 0 => break,
                _ => {}
            }
            k += 1;
        }
        if let Some(s) = ret_start {
            f.ret = render(&toks[s..k.min(end)]);
        }
        while k < end && !matches!(toks[k], Tok::P('{' | ';')) {
            k += 1; // where 절
        }
        if toks.get(k) != Some(&Tok::P('{')) {
            return (k + 1, Some(f)); // 몸통 없음(트레이트의 필수 메서드)
        }
        let body_end = matching(toks, k);
        f.has_body = true;
        f.calls = calls_in(&toks[k + 1..body_end]);
        // 지역 항목 — 몸통 안의 impl 은 전역 메서드다(자유 fn 은 밖에서 못 부른다).
        let module = format!("{stem}::{name}");
        self.fn_items(stem, &module, toks, k + 1, body_end, true);
        (body_end + 1, Some(f))
    }

    /// `toks[j]` 가 `impl` — 고유 impl 이면 `pub fn` 을, 트레이트 impl 이면 모든 fn 을 모은다.
    fn impl_block(&mut self, stem: &str, toks: &[Tok], j: usize, end: usize) -> usize {
        let start = skip_angles(toks, j + 1);
        let (k, fact) = impl_header(toks, j + 1);
        if k >= end || toks.get(k) != Some(&Tok::P('{')) {
            return k + 1;
        }
        let close = matching(toks, k);
        let (trait_name, owner) = match fact {
            Some((tr, ty)) => (Some(tr), Some(ty)),
            None => {
                let ty_end = toks[start..k]
                    .iter()
                    .position(|t| *t == Tok::Id("where".into()))
                    .map_or(k, |p| start + p);
                (None, last_top_ident(&toks[start..ty_end]))
            }
        };
        if toks.get(start) == Some(&Tok::P('!')) {
            return close + 1; // 부정 impl(`impl !Send for T`)
        }
        let mut i = k + 1;
        let mut test_only = false;
        while i < close {
            if let Some((attr, next)) = attribute(toks, i) {
                test_only |= attr.is_some_and(is_cfg_test);
                i = next;
                continue;
            }
            if std::mem::take(&mut test_only) {
                i = skip_item(toks, i).min(close);
                continue;
            }
            let (m, public) = visibility(toks, i);
            let m = skip_qualifiers(toks, m);
            i = if id(toks.get(m)) == Some("fn") {
                let (next, f) = self.fn_decl(stem, toks, m, close);
                if let Some(mut f) = f {
                    let ty = owner.clone().unwrap_or_else(|| "?".into());
                    f.label = match &trait_name {
                        Some(tr) => format!("<{ty} as {tr}>::{}", f.name),
                        None => format!("{ty}::{}", f.name),
                    };
                    f.owner = Some(ty);
                    f.trait_name = trait_name.clone();
                    f.vis_pub = public;
                    self.fns.push(f);
                }
                next
            } else {
                self.flag_item_macro(stem, toks, m, "impl 본문");
                skip_item(toks, i).max(i + 1)
            }
            .min(close);
        }
        close + 1
    }

    /// `toks[j]` 가 `trait` — 이름·가시성을 적고, 기본 몸통이 있는 fn 을 `Tr::m` 으로 모은다.
    fn trait_block(
        &mut self,
        stem: &str,
        toks: &[Tok],
        j: usize,
        end: usize,
        public: bool,
    ) -> usize {
        let Some(name) = id(toks.get(j + 1)).map(str::to_string) else {
            return j + 1;
        };
        self.traits.insert(name.clone(), public);
        let Some(open) = (j + 2..end).find(|&k| matches!(toks[k], Tok::P('{' | ';'))) else {
            return end;
        };
        if toks[open] == Tok::P(';') {
            return open + 1;
        }
        let close = matching(toks, open);
        let mut i = open + 1;
        while i < close {
            if let Some((_, next)) = attribute(toks, i) {
                i = next;
                continue;
            }
            let m = skip_qualifiers(toks, i);
            i = if id(toks.get(m)) == Some("fn") {
                let (next, f) = self.fn_decl(stem, toks, m, close);
                if let Some(mut f) = f.filter(|f| f.has_body) {
                    f.label = format!("{name}::{}", f.name);
                    f.trait_name = Some(name.clone());
                    f.vis_pub = public;
                    self.fns.push(f);
                }
                next
            } else {
                self.flag_item_macro(stem, toks, m, "트레이트 본문");
                skip_item(toks, i).max(i + 1)
            }
            .min(close);
        }
        close + 1
    }
}

/// `unsafe`·`async`·`const`·`default`·`extern "C"` 를 건너뛴다.
pub fn skip_qualifiers(toks: &[Tok], mut k: usize) -> usize {
    loop {
        match (id(toks.get(k)), toks.get(k + 1)) {
            (Some("extern"), Some(Tok::Lit)) => k += 2,
            (Some("unsafe" | "async" | "const" | "default" | "extern"), _)
                if matches!(
                    id(toks.get(k + 1)),
                    Some("fn" | "unsafe" | "async" | "const" | "extern" | "impl" | "trait")
                ) =>
            {
                k += 1
            }
            _ => return k,
        }
    }
}

/// 괄호·꺾쇠 깊이 0 의 `,` 로 가른다(빈 조각은 버린다 — 끝의 쉼표).
pub fn split_top(toks: &[Tok]) -> Vec<&[Tok]> {
    let mut out = Vec::new();
    let (mut depth, mut angle, mut from) = (0i32, 0i32, 0);
    for (k, t) in toks.iter().enumerate() {
        match t {
            Tok::P('(' | '[' | '{') => depth += 1,
            Tok::P(')' | ']' | '}') => depth -= 1,
            Tok::P('<') => angle += 1,
            Tok::P('>') if closes_angle(toks, k) => angle -= 1,
            Tok::P(',') if depth == 0 && angle == 0 => {
                out.push(&toks[from..k]);
                from = k + 1;
            }
            _ => {}
        }
    }
    out.push(&toks[from..]);
    out.into_iter().filter(|s| !s.is_empty()).collect()
}

/// 인자 하나 → `Some((이름, 타입))`, `self` 면 `None`. 앞의 속성(`#[…]`)은 건너뛴다.
pub fn param(seg: &[Tok]) -> Option<(String, String)> {
    let mut k = 0;
    while k < seg.len()
        && let Some((_, next)) = attribute(seg, k)
    {
        k = next;
    }
    let seg = &seg[k.min(seg.len())..];
    // 패턴 끝 = 깊이 0 의 단독 `:`(경로의 `::` 가 아니다).
    let colon = (0..seg.len()).find(|&k| {
        seg[k] == Tok::P(':')
            && seg.get(k + 1) != Some(&Tok::P(':'))
            && (k == 0 || seg[k - 1] != Tok::P(':'))
    });
    let pat = &seg[..colon.unwrap_or(seg.len())];
    let is_self = pat.iter().any(|t| *t == Tok::Id("self".into()));
    if is_self {
        return None;
    }
    let name = pat
        .iter()
        .find_map(|t| match t {
            Tok::Id(s) if s != "mut" && s != "ref" => Some(s.clone()),
            _ => None,
        })
        .filter(|_| !matches!(pat.first(), Some(Tok::P('(' | '['))))
        .unwrap_or_else(|| "_".into());
    let ty = colon.map_or_else(String::new, |c| render(&seg[c + 1..]));
    Some((name, ty))
}

/// 토큰 → 읽을 수 있는 타입 글자. 식별자 둘 사이에만 공백을 둔다(`dyn Tr`·`impl Into<String>`).
pub fn render(toks: &[Tok]) -> String {
    let mut out = String::new();
    let mut prev_word = false;
    for t in toks {
        let (s, word) = match t {
            Tok::Id(s) => (s.clone(), true),
            Tok::P(c) => (c.to_string(), false),
            Tok::Lit => ("…".to_string(), true),
            Tok::Life => ("'_".to_string(), true),
        };
        if prev_word && word {
            out.push(' ');
        }
        out.push_str(&s);
        prev_word = word;
    }
    out
}

/// 몸통이 부르는 이름 — `.x(`·`.x::<T>(`·`::x(`. 매크로(`x!(`)·선언은 아니다.
pub fn calls_in(body: &[Tok]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for (k, t) in body.iter().enumerate() {
        let Tok::Id(name) = t else { continue };
        let mut n = k + 1;
        if body.get(n) == Some(&Tok::P(':')) && body.get(n + 1) == Some(&Tok::P(':')) {
            n = skip_angles(body, n + 2); // 터보피시
        }
        let called = body.get(n) == Some(&Tok::P('('));
        let dot = k > 0 && body[k - 1] == Tok::P('.');
        let path = k > 1 && body[k - 1] == Tok::P(':') && body[k - 2] == Tok::P(':');
        if called && (dot || path) {
            out.insert(name.clone());
        }
    }
    out
}

/// 경로 호출 `Seg::x(` 의 `(Seg, x)` 전부 — 트레이트 정식 호출(`TokenProvider::access_token(a)`)을 가른다.
pub fn path_calls_in(body: &[Tok]) -> BTreeSet<(String, String)> {
    let mut out = BTreeSet::new();
    for k in 3..body.len() {
        if let (Tok::Id(seg), Tok::P(':'), Tok::P(':'), Tok::Id(name)) =
            (&body[k - 3], &body[k - 2], &body[k - 1], &body[k])
            && body.get(k + 1) == Some(&Tok::P('('))
        {
            out.insert((seg.clone(), name.clone()));
        }
    }
    out
}

/// 토큰과 그 글자 위치(`[시작, 끝)`) — 소스 조각을 원문으로 다시 읽어야 할 때(리터럴은 토큰에 없다).
pub fn lex_spans(src: &str) -> (Vec<char>, Vec<(Tok, usize, usize)>) {
    let c: Vec<char> = src.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < c.len() {
        let (next, tok) = lex_one(&c, i);
        if let Some(t) = tok {
            out.push((t, i, next));
        }
        i = next;
    }
    (c, out)
}

/// 파일 어디서든(`#[cfg(test)]` 모듈 안 포함) 이름이 `name` 인 fn 의 몸통 — `(부르는 이름, 경로 호출, 원문)`.
/// 손으로 고른 시험 함수(앵커)를 읽는 데 쓴다. 없으면 `None`.
pub fn fn_body(src: &str, name: &str) -> Option<FnBody> {
    let (chars, spans) = lex_spans(src);
    let toks: Vec<Tok> = spans.iter().map(|(t, _, _)| t.clone()).collect();
    let at = (0..toks.len().saturating_sub(1))
        .find(|&k| toks[k] == Tok::Id("fn".into()) && toks[k + 1] == Tok::Id(name.into()))?;
    let params = skip_angles(&toks, at + 2);
    if toks.get(params) != Some(&Tok::P('(')) {
        return None;
    }
    // 몸통 `{` 는 괄호·대괄호 깊이 0 에 있다 — 반환 타입 `[T; 2]` 의 `;` 에서 멈추면 안 된다.
    let mut depth = 0i32;
    let mut open = None;
    for (k, t) in toks.iter().enumerate().skip(matching(&toks, params) + 1) {
        match t {
            Tok::P('(' | '[') => depth += 1,
            Tok::P(')' | ']') => depth -= 1,
            Tok::P('{') if depth == 0 => {
                open = Some(k);
                break;
            }
            Tok::P(';') if depth == 0 => return None,
            _ => {}
        }
    }
    let open = open?;
    let close = matching(&toks, open);
    let body = &toks[open + 1..close];
    Some(FnBody {
        calls: calls_in(body),
        dot_calls: dot_calls_in(body),
        path_calls: path_calls_in(body),
        text: chars[spans[open].1..spans[close].2].iter().collect(),
    })
}

/// 메서드 호출 문법(`.x(`·`.x::<T>(`)으로 부르는 이름만.
pub fn dot_calls_in(body: &[Tok]) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    for (k, t) in body.iter().enumerate() {
        let Tok::Id(name) = t else { continue };
        let mut n = k + 1;
        if body.get(n) == Some(&Tok::P(':')) && body.get(n + 1) == Some(&Tok::P(':')) {
            n = skip_angles(body, n + 2);
        }
        if k > 0 && body[k - 1] == Tok::P('.') && body.get(n) == Some(&Tok::P('(')) {
            out.insert(name.clone());
        }
    }
    out
}

pub struct FnBody {
    /// `.x(`·`::x(` 로 부르는 이름 전부.
    pub calls: BTreeSet<String>,
    /// 그중 메서드 호출 문법(`.x(`)인 것.
    pub dot_calls: BTreeSet<String>,
    /// 경로 호출 `Seg::x(` 의 `(Seg, x)`.
    pub path_calls: BTreeSet<(String, String)>,
    pub text: String,
}

pub fn read_sources(dir: &Path, out: &mut Vec<(String, String)>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
        .map(|e| e.expect("dir entry").path())
        .collect();
    entries.sort();
    for p in entries {
        if p.is_dir() {
            read_sources(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            let stem = p.file_stem().expect("stem").to_string_lossy().into_owned();
            let src =
                std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
            out.push((stem, src));
        }
    }
}
