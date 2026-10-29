// index.html의 CHANGELOG 배열에서 CHANGELOG.md를 만든다. 사용: node tools/make_changelog.js
const fs = require("fs");
const src = fs.readFileSync(__dirname + "/../index.html", "utf8");
const m = src.match(/const CHANGELOG = (\[[\s\S]*?\n\]);/);
if (!m) throw new Error("CHANGELOG 배열을 찾지 못했어요");
const log = Function(`return ${m[1]}`)();
const lines = ["# 데모콕 · 버전 기록", "",
  "이 문서는 `index.html` 안의 `CHANGELOG`에서 자동으로 만들어진다. 직접 고치지 말고 `index.html`을 고친 뒤 다시 만든다.", "",
  "| 버전 | 날짜 | DB 변경 |", "| --- | --- | --- |",
  ...log.map(c => `| ${c.v} | ${c.date} | ${c.db ? "`" + c.db + "`" : "없음"} |`), ""];
for (const c of log) {
  lines.push(`## ${c.v} · ${c.date}`, "");
  for (const i of c.items) lines.push(`- ${i}`);
  if (c.db) lines.push("", `DB 변경: \`${c.db}\`를 SQL Editor에서 먼저 실행한다.`);
  lines.push("");
}
fs.writeFileSync(__dirname + "/../CHANGELOG.md", lines.join("\n"));
console.log("CHANGELOG.md:", log.length, "versions, latest", log[0].v);
