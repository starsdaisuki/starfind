# Spotlight tokenization of Chinese filenames

**English** · [简体中文](spotlight-cjk-tokenization.zh-CN.md)

Spotlight does not match CJK filenames by plain substring lookup. When digits and hyphens
sit between Chinese characters, the tokenization on the index side and on the query side
can disagree, so typing the complete filename may find nothing at all.

## Reproducible sample

Use a purpose-built test file:

```text
~/Documents/starfind-fixture/项目示例-1-年度总结与数据复盘.md
```

On some macOS versions a shorter Chinese fragment matches, while the full string
containing a "digit + hyphen + Chinese" boundary can fail. `kMDItemFSName ==` does not work
around this either, because Spotlight still applies its own lexical rules.

## How StarFind handles it

StarFind uses a two-stage query:

1. Run the normal `LIKE[cd] "*query*"` query first.
2. If the query completes with no results, split the CJK characters into AND conditions and
   query again.
3. Perform a genuine substring match on the candidates in memory.

Splitting into an AND only widens the candidate set. "The filename contains the original
query substring" necessarily implies "the filename contains every character of the query",
and the in-memory filter then narrows the results back to the original semantics, so no
extra noise is introduced.

## When the fallback is not used

| Case | Reason |
|---|---|
| The query has no CJK characters | There is nothing for the tokenization fallback to fix |
| The query contains a wildcard | The semantics are whole-filename matching, which cannot be re-checked by substring |
| A `content:` query | Hits come from file content, so they cannot be filtered by filename |

During a fallback query, `NSMetadataQuery.resultCount` reports the relaxed candidate count.
The interface should display the true count after in-memory filtering.

## Regression verification

`SelfTest.testCJKRelaxation` verifies:

- CJK character recognition and de-duplication
- The AND structure of the fallback predicate
- That wildcard, pure-ASCII and content queries do not fall back
- The AND, OR, exclusion and case-insensitive semantics of the in-memory filter
