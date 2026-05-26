# Content Creation Guidelines

This document provides comprehensive guidelines for creating blog content and other written materials for the website.

## Blog Writing Guidelines

### Overview

Blog posts target engineers and product managers, explaining complex topics simply without sacrificing technical accuracy. The writing should be clear, direct, and authoritative while remaining accessible.

### Writing Style

- **British English**: Use British spellings in content (e.g., 'optimise', 'realise', 'behaviour')
- **American English for URLs**: Use American spellings in slugs and filenames for SEO (e.g., `optimization` not `optimisation`). Most search traffic uses American spellings.
- **Oxford comma**: Always use the Oxford comma in lists
- **Direct and concise**: Use simple declarative sentences. Avoid:
  - Flowery language and purple prose
  - Unnecessary superlatives ("amazing", "incredible", "revolutionary")
  - Excessive adverbs ("really", "very", "extremely")
  - Superfluous words and filler phrases
  - **Comma splices**: Never join two independent clauses with just a comma. Use a full stop, semicolon, or em dash. Wrong: "The model is fast, it runs locally." Right: "The model is fast. It runs locally." or "The model is fast — it runs locally."
- **Proofread for missing words and typos**: Check for dropped articles (a/an/the), missing subjects ("and have a few days off" → "and I have a few days off"), missing relative pronouns ("a format contains" → "a format that contains"), and incorrect verb forms after auxiliaries ("started traverse" → "started traversing"). Also check for sentence fragments: subordinate clauses ("Which means...", "Because the...") that start a new sentence but lack an independent clause. Either join them to the previous sentence or rephrase with a proper subject ("This means..."). Parenthetical asides within a sentence start with a lowercase letter: "it takes ~300 ms (in pipecat, the timestamps from...)". Also run a spellcheck pass — common quick-draft errors include transposed letters ("avoding" → "avoiding"), dropped characters ("woktrees" → "worktrees"), and stray spaces in compound terms ("X- SIP" → "X-SIP")
- **No repetition**: Avoid repeating statements or concepts unless explicitly for emphasis or to improve readability in complex arguments. Within a single post, do not present the same information twice in different forms (e.g., a bullet summary and then a detailed section covering the same items) — pick one treatment and commit to it
- **Expand acronyms on first use**: Write "VAD (Voice Activity Detection)" on the first occurrence. Well-known acronyms in the target audience's domain (e.g., STT, LLM, API) may be left unexpanded
- **No duplicate links**: Do not link the same URL twice in the same paragraph. Link it once with the most descriptive anchor text and refer to it in plain text thereafter
- **Active voice**: Prefer active voice over passive voice
- **Personal perspective**: Use first-person narrative where appropriate ("I think", "we observed") to create connection
- **Avoid lists in body**: Do not use bullet points or numbered lists in the main body unless they improve clarity for procedural content. Lists should only appear:
  - In the introduction when outlining topics to be covered
  - At the end for concise summaries or key takeaways
  - **Tutorial/procedure exception**: For step-by-step instructions, short numbered lists are allowed in the body. Keep each step concise and support with prose where needed.
  - **TIL exception (selective)**: If a TIL is explicitly a collection of distinct, unrelated ideas, a short bullet list is allowed in the body. Keep it brief, add a one-sentence intro, and avoid lists when the content can be expressed as short paragraphs.
  - Use flowing prose and paragraphs for all other content

### Anti-LLM Authenticity Rules

Use these rules to avoid generic template output. Treat them as quality constraints, not proof of AI usage.

- **Concrete-first opener**: Start with a specific event, result, or problem from the work. Avoid meta framing such as "In this post, I'll cover...".
- **Evidence density**: Each major section must include at least one concrete anchor (command, file path, metric, error string, timestamp, named system, or explicit decision).
- **Decision with trade-off**: When you say "we chose X", include "instead of Y" and one downside.
- **Failure and adjustment**: Include at least one thing that failed (or nearly failed), why it failed, and what changed.
- **Original stance**: Include at least one non-obvious opinion grounded in the implementation details or outcome.
- **No abstraction-only paragraphs**: Every paragraph should contain evidence, a decision, or a result.
- **Avoid template phrases**: Avoid stock phrasing and AI-signalling vocabulary unless it is genuinely the best word. Avoid examples like "delve", "ever-evolving", "it is worth noting", "seamless", "leverage", "in conclusion", "this underscores", "this highlights", and "this landscape".
- **Avoid formulaic contrast patterns**: Don't overuse repetitive structures such as "not just X, but Y" or "not only X, but Y".
- **Avoid forced variation**: Do not rotate synonyms for the same concept just to sound varied. Prefer consistency over "elegant variation".
- **Control formatting tics**: Do not overuse em dashes, boldface, or repeated "rule of three" rhythms.
- **No assistant meta residue**: Remove phrases like "I hope this helps", "as of my last update", "would you like me to...", and any placeholder text (`[X]`, `{placeholder}`, `Subject:` scaffolding).
- **Final de-LLM pass**: Before finalising, run a focused pass to remove generic transitions, hedge-heavy filler, and templated recap lines.

### Structure Requirements

Note: TILs (Today I Learned posts) are exempt from the TL;DR and hero image requirements because they should be short. However, TILs still require a forward-looking close (even a single sentence) and should not end abruptly on a bullet list, bare code block, or bare link.

1. **TL;DR**: Start every post with a bolded `**TL;DR:**` that summarises the key message in 1-2 sentences
2. **Hero image**: Include a social media-optimised image after the TL;DR
3. **Hook**: Open with an engaging paragraph that sets context or presents a problem. Avoid cramming multiple links, product names, and technical details into the first paragraph — keep the opener focused and split dense information into subsequent paragraphs
4. **Headings**: Use H2 (`##`) for main sections and H3 (`###`) for subsections
5. **Code blocks**: Use fenced code blocks with language identifiers:
   ```typescript
   // Example code here
   ```
   When referencing technical terms inline, wrap them in backticks: HTML elements (`<track>`, `<video>`), filenames (`.gitignore`, `package.json`), CLI commands (`git worktree`), function names (`parseAuthParams`), environment variables (`NODE_ENV`), and config keys.
6. **Code-prose consistency**: When code examples use specific variable names, prefixes, or identifiers, the surrounding prose must reference them identically. Don't use `X-ft-*` in code and `X-ph-*` in the paragraph that explains it. After editing code, re-read the prose to catch stale references.
   - **Cross-block consistency**: When multiple code blocks form a single workflow, identifiers (labels, filenames, usernames, paths) must match across all blocks. A plist Label must match the string used in `launchctl` commands; a filename created in one snippet must be the filename referenced in the next. After finishing a draft, scan all code blocks as a group to verify shared identifiers agree.
7. **Code example completeness**: Code examples should be self-contained or explicitly mark what's been omitted (e.g., `// parseAuthParams omitted for brevity`). Don't reference functions that appear nowhere in the post. Also ensure code comments stay accurate after refactoring — stale comments that describe removed logic are misleading.
8. **Consistent command syntax**: When referencing a CLI tool or command, use the same invocation form throughout the post. Do not mix slash commands (`/fan-out`) with script paths (`./fan-out`) or other forms — pick one and stick with it
9. **Length**: Default target is 800-1,500 words. Content-type ranges below can override this when justified.

### Content Approach

1. **Layered explanations**: Introduce complex topics progressively:
   - High-level concept introduction
   - Detailed technical explanation
   - Practical examples or use cases
   - Real-world implications

2. **Use analogies**: Connect new concepts to familiar technical concepts (e.g., comparing AI reliability to TCP/UDP networking)

3. **Concrete examples**: Ground abstract concepts with:
   - Real company names and products
   - Actual code snippets
   - Personal anecdotes where relevant
   - Specific metrics and benchmarks

4. **Problem-solution narrative**: Structure posts to:
   - Present a relatable problem
   - Explore underlying issues
   - Present solutions or insights
   - Conclude with forward-looking implications

5. **Show the result**: Don't just describe the process — tell the reader what the outcome was. Did it work? What did it feel like? Was it good, surprising, or disappointing? The payoff is what makes the reader care.

6. **Deliver on the title**: The body must fulfil the promise the title makes. If the title says "in under 5 minutes," the text must address the timing. If it says "remote voice conversations," open with a scenario that demonstrates it. For TILs especially, re-check the title after finishing the draft — TIL titles are often written first and drift from the final content

7. **Include rough edges**: Mention limitations, caveats, or things that didn't work. All-positive write-ups read as promotional. Candour about what's broken or incomplete builds credibility.

8. **Give your best lines room to breathe**: Strong analogies and memorable phrases ("think karaoke for voice cloning") deserve their own sentence or short paragraph. Don't bury them mid-paragraph where they're easy to miss.

9. **Attribute references**: Blockquotes, statistics, and technical claims from external sources must link to the source. Don't leave quotes floating without attribution.

### Technical Requirements

- **Markdown output**: All blog posts must be in Markdown format
- **Frontmatter**: Use the following YAML format:
  ```yaml
  ---
  title: 'Your Blog Title Here'
  slug: 'url-slug-for-the-post'
  excerpt: 'A brief description of the post for SEO and social sharing'
  published_date: 'YYYY-MM-DD'
  status: 'published'
  category: 'Industry' | 'Engineering'
  tags: ['tag1', 'tag2', 'tag3']
  authors: ['Varun Singh']
  ---
  ```
- **TIL frontmatter**: TILs use a simpler format:
  ```yaml
  ---
  title: 'Your TIL Title Here'
  published_date: 'YYYY-MM-DD'
  status: 'published'
  audio_url: /static/audio/til/{tag}/{slug}.aac   # optional
  ---
  ```
- **Post-publication updates**: When appending new information to a published post, use a bold label with the year-month: `**Updated (YYYY-MM)**: …`. Place updates at the end of the post, before any closing/forward-looking sentence. Keep updates self-contained — a reader skimming should understand the update without re-reading the whole post
- **Images**: Store source hero-image PNGs in `/images/wip/`. Generated/optimised social images are stored in `/images/blog/YYYY/`
- **File naming**: Use kebab-case for filenames matching the URL slug

### Before Writing

Always ask for clarification on:

1. The specific technical audience (e.g., frontend engineers, DevOps, product managers)
2. The desired depth of technical detail
3. Any specific technologies or frameworks to reference
4. Whether code examples should be included
5. If the topic requires multiple parts

### Quality Checklist

- [ ] Clear TL;DR that captures the essence
- [ ] Engaging opening that hooks the reader
- [ ] Complex topics explained simply
- [ ] Technical accuracy maintained throughout
- [ ] No unnecessary repetition
- [ ] British English spelling used consistently
- [ ] Oxford comma used in all lists
- [ ] Active voice predominates
- [ ] Length matches the target for the selected content type
- [ ] Code blocks properly formatted with language identifiers
- [ ] Structured with clear H2/H3 headings
- [ ] Ends with synthesis and forward-looking statement (including TILs)
- [ ] No comma splices
- [ ] Title promise fulfilled in the body
- [ ] Result/outcome shown, not just process
- [ ] Rough edges or limitations acknowledged
- [ ] Quotes and references attributed with links
- [ ] Image alt text is descriptive (not just the subject name)
- [ ] No missing articles, subjects, relative pronouns, or verb form errors
- [ ] No typos or misspellings (spellcheck pass completed)
- [ ] Command/CLI syntax consistent throughout the post
- [ ] All technical terms in backticks (filenames, functions, CLI commands, env vars)
- [ ] Code examples match surrounding prose (variable names, prefixes, identifiers)
- [ ] Code examples are self-contained or explicitly mark omissions
- [ ] Code comments accurate (no stale comments from prior refactors)
- [ ] No duplicate information presented in two forms within the same post
- [ ] Acronyms expanded on first use (except well-known: STT, LLM, API)
- [ ] No duplicate links (same URL linked twice in the same paragraph)
- [ ] Opening paragraph starts with a concrete event/result, not meta framing
- [ ] Each major section includes at least one concrete anchor (command/path/metric/error/decision)
- [ ] At least one explicit trade-off is stated (`chose X instead of Y`, with downside)
- [ ] At least one failed attempt (or rough edge) and adjustment is documented
- [ ] No templated AI-signalling phrases or assistant meta residue
- [ ] Final de-LLM pass completed (generic transitions and filler removed)

### TIL-Specific Checklist

TILs are shorter and skip some blog requirements. Use this subset instead of the full checklist above:

- [ ] Title matches the content (re-check after finishing the draft)
- [ ] Frontmatter has `title`, `published_date`, `status`; optional `audio_url`
- [ ] British English spelling used consistently
- [ ] No comma splices
- [ ] Code blocks have language identifiers
- [ ] All technical terms in backticks
- [ ] Code examples match surrounding prose (variable names, prefixes, identifiers)
- [ ] Cross-block consistency: shared identifiers (labels, filenames, usernames) match across all code blocks
- [ ] Code examples are self-contained or explicitly mark omissions
- [ ] No typos or misspellings
- [ ] Acronyms expanded on first use (except well-known: STT, LLM, API)
- [ ] No duplicate links (same URL linked twice in the same paragraph)
- [ ] Opening line uses a concrete event/result, not "In this post..." style framing
- [ ] Includes at least one concrete anchor (command/path/metric/error/decision)
- [ ] Includes one trade-off or one failed attempt plus adjustment
- [ ] No templated AI-signalling phrases or assistant meta residue
- [ ] Does not end abruptly on a bare code block, bullet list, or link
- [ ] Ends with a forward-looking close (even a single sentence)
- [ ] Post-publication updates use `**Updated (YYYY-MM)**:` format

## SEO and Social Media Guidelines

### Hero Image Requirements

- **Dimensions**: 1200x630px (social media standard)
- **Format**: PNG source files in `/images/wip/`, converted to optimised JPG
- **Title placement**: y=160-230px (upper area, safe from overlays)
- **Style**: Professional, technical, with space for text overlay
- **Naming**: Descriptive filename matching content theme

### Social Media Optimisation

- **Open Graph**: Automatically generated from frontmatter
- **Twitter Cards**: Large image format with proper metadata
- **Excerpts**: 150-160 characters for optimal social sharing
- **Tags**: 3-5 relevant tags for discoverability
- **Categories**: Consistent categorisation for content organisation

### Search Engine Optimisation

- **Structured data**: JSON-LD markup automatically generated
- **Meta descriptions**: Crafted from excerpt field
- **URL structure**: Clean, descriptive slugs
- **Internal linking**: Reference related posts and topics
- **Image alt text**: Descriptive alt attributes for accessibility

## Content Management Workflow

### Creating New Blog Posts

1. **Planning**: Outline key points and target audience
2. **Creation**: Use `npm run blog:create` interactive CLI
3. **Writing**: Follow guidelines and quality checklist
4. **Images**: Add hero images to `/images/wip/` as PNG files
5. **Review**: Validate content against checklist
6. **Publishing**: Use `./scripts/update-blog.sh` for local sync
7. **Production**: Use `./scripts/update-blog.sh --remote` for live deployment

### Content Review Process

1. **Technical accuracy**: Verify all technical claims and code examples. Check exact tool names, API methods, and library references against official documentation — don't guess from memory
2. **Style consistency**: Ensure adherence to writing style guidelines
3. **SEO optimisation**: Check metadata, images, and structure
4. **Accessibility**: Validate heading hierarchy and alt text
5. **Cross-referencing**: Link to related content where appropriate

### Content Updates and Maintenance

- **Regular review**: Quarterly review of content for accuracy
- **Link maintenance**: Check and update external references
- **Image optimisation**: Ensure images remain optimised and accessible
- **Category consistency**: Maintain consistent categorisation
- **Tag management**: Regular cleanup and consolidation of tags

## Voice and Tone Guidelines

### Technical Authority

- Demonstrate deep understanding without being condescending
- Acknowledge complexity while making content accessible
- Use precise technical terminology appropriately
- Provide context for industry-specific concepts

### Personal Touch

- Share relevant personal experiences and insights
- Use "I" and "we" appropriately to create connection
- Include lessons learned from real-world implementations
- Balance confidence with intellectual humility

### Engagement Style

- Write conversationally but professionally
- Use rhetorical questions sparingly and purposefully
- Create clear narrative flow between sections
- End with actionable insights or future considerations

## Content Types and Formats

### Technical Deep Dives

- **Structure**: Problem → Analysis → Solution → Implementation → Results
- **Length**: 1,200-2,000 words
- **Code examples**: Essential, with proper syntax highlighting
- **Diagrams**: Use when helpful for complex concepts

### Industry Analysis

- **Structure**: Context → Trend Analysis → Implications → Predictions
- **Length**: 800-1,200 words
- **Data**: Include relevant metrics and benchmarks
- **References**: Link to authoritative sources

### Tutorial Content

- **Structure**: Prerequisites → Step-by-step → Troubleshooting → Next Steps
- **Length**: 1,000-1,800 words
- **Code samples**: Complete, tested examples
- **Screenshots**: When necessary for clarity

### Opinion and Commentary

- **Structure**: Thesis → Supporting Evidence → Counter-arguments → Conclusion
- **Length**: 800-1,200 words
- **Personal experience**: Essential for credibility
- **Balanced perspective**: Acknowledge alternative viewpoints
