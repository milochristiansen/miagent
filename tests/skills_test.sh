#!/bin/sh
# Exercise the bundled activate_skill TGI tool directly: discovery, schema
# generation, lenient parsing, precedence, activation, and error handling.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/tools/activate_skill"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

export HOME="$TMP/home"
export MIAGENT_CONFIG_DIR="$TMP/config"
PROJECT="$TMP/project"
mkdir -p "$HOME/.agents/skills" "$MIAGENT_CONFIG_DIR/skills" \
         "$PROJECT/.agents/skills" "$PROJECT/.miagent/skills"
unset MIAGENT_SKILLS MIAGENT_SKILLS_PROJECT MIAGENT_SKILLS_DIRS TGI_ATTACHMENT_DIR 2>/dev/null || true

fail() {
    echo "skills_test: $*" >&2
    exit 1
}

clear_skills() {
    rm -rf "$HOME/.agents/skills" "$MIAGENT_CONFIG_DIR/skills" \
           "$PROJECT/.agents/skills" "$PROJECT/.miagent/skills"
    mkdir -p "$HOME/.agents/skills" "$MIAGENT_CONFIG_DIR/skills" \
             "$PROJECT/.agents/skills" "$PROJECT/.miagent/skills"
}

write_skill() {
    dir=$1
    name=$2
    description=$3
    body=$4
    mkdir -p "$dir"
    {
        printf '%s\n' '---'
        printf 'name: %s\n' "$name"
        printf 'description: %s\n' "$description"
        printf '%s\n' '---'
        printf '%s\n' "$body"
    } > "$dir/SKILL.md"
}

schema() {
    ( cd "$PROJECT" && TGI_METHOD=SCHEMA TGI_TOOL=activate_skill "$TOOL" )
}

invoke() {
    name=$1
    shift || true
    ( cd "$PROJECT" && TGI_METHOD=INVOKE TGI_TOOL=activate_skill "$TOOL" <<EOF
{"name":"$name"}
EOF
    )
}

echo "== no skills is silent"
clear_skills
out=$(schema)
[ -z "$out" ] || fail "schema was not empty with no skills: $out"

echo "== schema contains catalog and enum"
clear_skills
write_skill "$PROJECT/.agents/skills/pdf-processing" pdf-processing \
    "Extract PDF text, fill forms, merge files. Use when handling PDFs." \
    "# PDF Processing"
out=$(schema)
printf '%s' "$out" | jq -e '.name == "activate_skill"' >/dev/null || fail "wrong tool name"
printf '%s' "$out" | jq -e '.parameters.properties.name.enum == ["pdf-processing"]' >/dev/null || fail "wrong enum"
printf '%s' "$out" | jq -e '.description | contains("pdf-processing")' >/dev/null || fail "catalog missing skill name"

echo "== bundled TGI skill"
clear_skills
cp -R "$ROOT/skills/tgi-tools" "$MIAGENT_CONFIG_DIR/skills/"
out=$(schema)
printf '%s' "$out" | jq -e '.parameters.properties.name.enum == ["tgi-tools"]' >/dev/null || fail "bundled TGI skill not discovered"
printf '%s' "$out" | jq -e '.description | contains("TGI")' >/dev/null || fail "bundled TGI skill description missing"
attach="$TMP/attach-tgi"
mkdir -p "$attach"
TGI_ATTACHMENT_DIR="$attach" invoke tgi-tools >/dev/null
grep -q 'Writing MiAgent TGI Tools' "$attach/nuggets/skills/tgi-tools.md" || fail "TGI skill body missing"
grep -q '<file>references/TGI.md</file>' "$attach/nuggets/skills/tgi-tools.md" || fail "TGI skill reference not listed"
grep -q '# Tools, TGI, and MiAgent' "$ROOT/skills/tgi-tools/references/TGI.md" || fail "TGI skill reference is missing its body"

echo "== lenient frontmatter parsing"
clear_skills
mkdir -p "$PROJECT/.agents/skills/block-skill" "$PROJECT/.agents/skills/colon-skill" \
         "$PROJECT/.agents/skills/quoted-skill"
cat > "$PROJECT/.agents/skills/block-skill/SKILL.md" <<'EOF'
---
name: block-skill
description: |
  First line.
  Second line: with a colon.
compatibility: >
  Requires jq
  and bash.
---
# Block
EOF
printf -- '---\r\nname: colon-skill\r\ndescription: Use this skill when: the user asks about PDFs\r\n---\r\n# Colon\r\n' \
    > "$PROJECT/.agents/skills/colon-skill/SKILL.md"
printf '\357\273\277---\nname: quoted-skill\ndescription: \x27It\x27\x27s quoted.\x27\n---\n# Quoted\n' \
    > "$PROJECT/.agents/skills/quoted-skill/SKILL.md"
out=$(schema)
printf '%s' "$out" | jq -e '.description | contains("block-skill: First line. Second line: with a colon.")' >/dev/null || fail "block scalar parse"
printf '%s' "$out" | jq -e '.description | contains("colon-skill: Use this skill when: the user asks about PDFs")' >/dev/null || fail "colon parse"
printf '%s' "$out" | jq -e --arg expected "quoted-skill: It's quoted." '.description | contains($expected)' >/dev/null || fail "quote parse"

echo "== malformed skills are skipped"
clear_skills
mkdir -p "$PROJECT/.agents/skills/missing-desc" "$PROJECT/.agents/skills/no-frontmatter"
printf '%s\n' '---' 'name: missing-desc' '---' '# Body' > "$PROJECT/.agents/skills/missing-desc/SKILL.md"
printf '%s\n' '# No frontmatter' > "$PROJECT/.agents/skills/no-frontmatter/SKILL.md"
write_skill "$PROJECT/.agents/skills/valid-skill" valid-skill "valid" "# Valid"
out=$(schema)
printf '%s' "$out" | jq -e '.parameters.properties.name.enum == ["valid-skill"]' >/dev/null || fail "malformed skills were not skipped"

echo "== name warnings do not block loading"
clear_skills
long_name=$(printf '%065d' 0 | tr '0' 'a')
mkdir -p "$PROJECT/.agents/skills/short-dir"
cat > "$PROJECT/.agents/skills/short-dir/SKILL.md" <<EOF
---
name: $long_name
description: long and mismatched
---
# Long
EOF
out=$(schema 2> "$TMP/name.err")
printf '%s' "$out" | jq -e --arg name "$long_name" '.parameters.properties.name.enum == [$name]' >/dev/null || fail "long name was not loaded"
grep -q 'does not match directory' "$TMP/name.err" || fail "missing name-mismatch warning"
grep -q 'longer than 64' "$TMP/name.err" || fail "missing long-name warning"

echo "== precedence and shadow warning"
clear_skills
for root in "$HOME/.agents/skills" "$MIAGENT_CONFIG_DIR/skills" \
            "$PROJECT/.agents/skills" "$PROJECT/.miagent/skills"; do
    write_skill "$root/dup" dup "from $root" "# Dup"
done
out=$(schema 2> "$TMP/shadow.err")
printf '%s' "$out" | jq -e '.parameters.properties.name.enum == ["dup"]' >/dev/null || fail "duplicate enum"
printf '%s' "$out" | jq -e --arg root "$PROJECT/.miagent/skills" '.description | contains($root)' >/dev/null || fail "project-native did not win"
grep -q 'shadowed' "$TMP/shadow.err" || fail "missing shadow warning"

echo "== project and global disabling"
out=$(MIAGENT_SKILLS_PROJECT=0 schema 2>/dev/null)
printf '%s' "$out" | jq -e --arg root "$MIAGENT_CONFIG_DIR/skills" '.description | contains($root)' >/dev/null || fail "project scope was not disabled"
out=$(MIAGENT_SKILLS=0 schema)
[ -z "$out" ] || fail "MIAGENT_SKILLS=0 still advertised tools"

echo "== extra skill roots"
clear_skills
mkdir -p "$TMP/extra/extra-skill"
write_skill "$TMP/extra/extra-skill" extra-skill "extra" "# Extra"
out=$(MIAGENT_SKILLS_DIRS="$TMP/extra" schema)
printf '%s' "$out" | jq -e '.parameters.properties.name.enum == ["extra-skill"]' >/dev/null || fail "MIAGENT_SKILLS_DIRS was not scanned"

echo "== activation writes a nugget"
clear_skills
mkdir -p "$PROJECT/.agents/skills/pdf-processing/scripts" \
         "$PROJECT/.agents/skills/pdf-processing/references"
cat > "$PROJECT/.agents/skills/pdf-processing/SKILL.md" <<'EOF'
---
name: pdf-processing
description: Extract PDF text, fill forms, merge files. Use when handling PDFs.
compatibility: Requires Python 3.14+ and uv
---
# PDF Processing

Use this skill when the user needs to work with PDF files.
EOF
printf 'print("hi")\n' > "$PROJECT/.agents/skills/pdf-processing/scripts/extract.py"
printf '# Ref\n' > "$PROJECT/.agents/skills/pdf-processing/references/REFERENCE.md"
attach="$TMP/attach"
mkdir -p "$attach"
out=$(TGI_ATTACHMENT_DIR="$attach" invoke pdf-processing)
printf '%s' "$out" | grep -q 'activated skill "pdf-processing"' || fail "missing activation acknowledgement"
nugget="$attach/nuggets/skills/pdf-processing.md"
[ -f "$nugget" ] || fail "nugget was not written"
grep -q '# PDF Processing' "$nugget" || fail "body missing"
grep -q 'Skill directory: ' "$nugget" || fail "skill directory missing"
grep -q '<file>scripts/extract.py</file>' "$nugget" || fail "script resource missing"
grep -q '<file>references/REFERENCE.md</file>' "$nugget" || fail "reference resource missing"
grep -q 'Compatibility: Requires Python 3.14+' "$nugget" || fail "compatibility missing"
if grep -q '^name: pdf-processing' "$nugget"; then fail "frontmatter leaked into nugget"; fi

echo "== empty body still produces a useful nugget"
clear_skills
write_skill "$PROJECT/.agents/skills/empty-skill" empty-skill "empty body" ""
attach="$TMP/attach-empty"
mkdir -p "$attach"
TGI_ATTACHMENT_DIR="$attach" invoke empty-skill >/dev/null
grep -q 'This skill has no body instructions.' "$attach/nuggets/skills/empty-skill.md" || fail "empty-body note missing"

echo "== unknown skill is an error"
attach="$TMP/attach-unknown"
mkdir -p "$attach"
if TGI_ATTACHMENT_DIR="$attach" invoke does-not-exist >/dev/null 2>"$TMP/unknown.err"; then
    fail "unknown skill unexpectedly succeeded"
fi
grep -q "unknown skill" "$TMP/unknown.err" || fail "unknown skill error missing"
[ ! -e "$attach/nuggets/skills/does-not-exist.md" ] || fail "unknown skill wrote a nugget"

echo "== missing attachment dir is an error"
if invoke empty-skill >/dev/null 2>"$TMP/no-attach.err"; then
    fail "activation without TGI_ATTACHMENT_DIR unexpectedly succeeded"
fi
grep -q 'TGI_ATTACHMENT_DIR' "$TMP/no-attach.err" || fail "missing attachment error missing"

echo "== resource listing is capped"
clear_skills
mkdir -p "$PROJECT/.agents/skills/many-files/files"
write_skill "$PROJECT/.agents/skills/many-files" many-files "many files" "# Many"
i=1
while [ "$i" -le 205 ]; do
    : > "$PROJECT/.agents/skills/many-files/files/file-$i.txt"
    i=$((i + 1))
done
attach="$TMP/attach-many"
mkdir -p "$attach"
TGI_ATTACHMENT_DIR="$attach" invoke many-files >/dev/null
grep -q 'listing truncated after 200 files; 5 more not listed' "$attach/nuggets/skills/many-files.md" || fail "truncation note missing"

echo "== path-like skill names cannot escape the nugget directory"
clear_skills
mkdir -p "$PROJECT/.agents/skills/evil-skill"
cat > "$PROJECT/.agents/skills/evil-skill/SKILL.md" <<'EOF'
---
name: ../evil
description: path-like name
---
# Evil
EOF
attach="$TMP/attach-evil"
mkdir -p "$attach"
TGI_ATTACHMENT_DIR="$attach" invoke "../evil" >/dev/null 2>/dev/null || true
if find "$attach" -type f | grep -q '/evil.md$'; then
    fail "path-like name escaped the nugget directory"
fi
if [ -f "$attach/nuggets/skills/-evil.md" ]; then :; else
    fail "sanitized namespace did not contain the path-like name"
fi

echo "skills_test: ok"
