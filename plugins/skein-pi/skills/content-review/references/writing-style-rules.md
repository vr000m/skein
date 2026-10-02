# Universal Writing Style Rules

These rules apply to all content types reviewed by the content-review skill, regardless of whether the content is a blog post, TIL, technical document, Notion page, or general writing.

## Language

- **British English**: Use British spellings in content (e.g., 'optimise', 'realise', 'behaviour', 'colour', 'organised', 'summarise', 'analyse', 'centre', 'licence' [noun], 'defence', 'programme' [non-computing])
- **Oxford comma**: Always use the Oxford comma in lists (e.g., "red, green, and blue" not "red, green and blue")

## Prose Quality

- **Active voice**: Prefer active voice over passive voice. Flag passive constructions, especially in key claims and opening sentences.
- **Direct and concise**: Use simple declarative sentences. Flag:
  - Flowery language and purple prose
  - Unnecessary superlatives ("amazing", "incredible", "revolutionary")
  - Excessive adverbs ("really", "very", "extremely")
  - Superfluous words and filler phrases
- **No comma splices**: Never join two independent clauses with just a comma. Acceptable alternatives: full stop, semicolon, em dash, or conjunction. Wrong: "The model is fast, it runs locally." Right: "The model is fast. It runs locally." or "The model is fast — it runs locally."
- **No repetition**: Do not present the same information twice in different forms within the same piece. Pick one treatment and commit to it.

## Proofreading

- Check for dropped articles (a/an/the)
- Check for missing subjects ("and have a few days off" should be "and I have a few days off")
- Check for missing relative pronouns ("a format contains" should be "a format that contains")
- Check for incorrect verb forms after auxiliaries ("started traverse" should be "started traversing")
- Spellcheck for transposed letters ("avoding" -> "avoiding"), dropped characters ("woktrees" -> "worktrees"), stray spaces in compound terms ("X- SIP" -> "X-SIP")

## Code and Technical Terms

- Wrap technical terms in backticks: filenames (`.gitignore`), function names (`parseAuthParams`), CLI commands (`git worktree`), environment variables (`NODE_ENV`), config keys, HTML elements (`<video>`)
- Code blocks must use fenced syntax with language identifiers (e.g., ```typescript)
- Code examples must match surrounding prose — variable names, prefixes, and identifiers referenced in text must match what appears in code
- When multiple code blocks form a workflow, shared identifiers (labels, filenames, paths) must be consistent across all blocks
- Code examples should be self-contained or explicitly mark omissions (e.g., `// omitted for brevity`)
- Code comments must be accurate — no stale comments describing removed logic
- Use the same invocation form for CLI tools throughout (don't mix `/command` with `./command`)
