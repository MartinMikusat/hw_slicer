<script lang="ts">
  import { onMount } from "svelte";

  type SourceStatus = "adopted" | "candidate" | "background" | "rejected" | "unreviewed";
  type SourceType = "paper" | "report" | "specification" | "documentation";

  type ResearchSource = {
    id: string;
    citationKey: string;
    type: SourceType;
    title: string;
    authors: string[];
    year: number;
    publication: string;
    publisher: string;
    volume: string | null;
    issue: string | null;
    pages: string | null;
    doi: string | null;
    url: string;
    topics: string[];
    status: SourceStatus;
    confidence: "high" | "medium" | "low";
    planSections: string[];
    summary: string;
    keyFindings: string[];
    limitations: string[];
    usage: {
      decision: string;
      targets: string[];
    };
    notePath: string;
    pdf: {
      path: string;
      sourceUrl: string;
      sha256: string;
      provenance: string;
      accessNote: string;
      retrieved: string;
    } | null;
  };

  type ResearchCatalog = {
    schemaVersion: number;
    reviewedThrough: string;
    sources: ResearchSource[];
  };

  let catalog = $state<ResearchCatalog | null>(null);
  let loadError = $state("");
  let query = $state("");
  let statusFilter = $state<SourceStatus | "all">("all");
  let typeFilter = $state<SourceType | "all">("all");
  let archiveFilter = $state<"all" | "snapshot" | "link">("all");
  let topicFilter = $state("all");
  let selectedId = $state<string | null>(null);
  let copiedKey = $state<string | null>(null);
  let theme = $state<"light" | "dark">("light");
  let searchInput: HTMLInputElement;

  const statusOptions: Array<SourceStatus | "all"> = [
    "all",
    "adopted",
    "candidate",
    "background"
  ];
  const typeOptions: Array<SourceType | "all"> = [
    "all",
    "paper",
    "report",
    "specification",
    "documentation"
  ];

  const topics = $derived(
    catalog
      ? [...new Set(catalog.sources.flatMap((source) => source.topics))].sort((a, b) =>
          a.localeCompare(b)
        )
      : []
  );

  function normalizedSearchText(source: ResearchSource) {
    return [
      source.title,
      source.authors.join(" "),
      source.publication,
      source.summary,
      source.usage.decision,
      source.topics.join(" "),
      source.planSections.join(" "),
      source.citationKey
    ]
      .join(" ")
      .toLowerCase();
  }

  function searchScore(source: ResearchSource, tokens: string[]) {
    if (tokens.length === 0) return source.year;

    const title = source.title.toLowerCase();
    const authors = source.authors.join(" ").toLowerCase();
    const topicsText = source.topics.join(" ").toLowerCase();
    const allText = normalizedSearchText(source);
    let score = 0;

    for (const token of tokens) {
      if (!allText.includes(token)) return -1;
      if (title.includes(token)) score += 8;
      if (authors.includes(token)) score += 5;
      if (topicsText.includes(token)) score += 4;
      score += 1;
    }

    return score;
  }

  const filteredSources = $derived.by(() => {
    if (!catalog) return [];

    const tokens = query
      .trim()
      .toLowerCase()
      .split(/\s+/)
      .filter(Boolean);

    return catalog.sources
      .filter((source) => statusFilter === "all" || source.status === statusFilter)
      .filter((source) => typeFilter === "all" || source.type === typeFilter)
      .filter((source) => topicFilter === "all" || source.topics.includes(topicFilter))
      .filter((source) => {
        if (archiveFilter === "snapshot") return source.pdf !== null;
        if (archiveFilter === "link") return source.pdf === null;
        return true;
      })
      .map((source) => ({ source, score: searchScore(source, tokens) }))
      .filter(({ score }) => score >= 0)
      .sort((a, b) => {
        if (tokens.length > 0 && b.score !== a.score) return b.score - a.score;
        if (b.source.year !== a.source.year) return b.source.year - a.source.year;
        return a.source.title.localeCompare(b.source.title);
      })
      .map(({ source }) => source);
  });

  const archivedCount = $derived(
    catalog?.sources.filter((source) => source.pdf !== null).length ?? 0
  );
  const adoptedCount = $derived(
    catalog?.sources.filter((source) => source.status === "adopted").length ?? 0
  );

  onMount(async () => {
    const storedTheme = localStorage.getItem("hw-slicer-research-theme");
    const preferredDark = matchMedia("(prefers-color-scheme: dark)").matches;
    theme = storedTheme === "dark" || (storedTheme === null && preferredDark) ? "dark" : "light";
    document.documentElement.dataset.theme = theme;

    try {
      const response = await fetch("/research-index.json");
      if (!response.ok) throw new Error(`Catalog request failed with ${response.status}.`);
      catalog = await response.json();
      selectedId = new URLSearchParams(location.search).get("source");
    } catch (error) {
      loadError = error instanceof Error ? error.message : "The research index could not load.";
    }
  });

  function setTheme(nextTheme: "light" | "dark") {
    theme = nextTheme;
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("hw-slicer-research-theme", theme);
  }

  function toggleTheme() {
    setTheme(theme === "light" ? "dark" : "light");
  }

  function selectSource(source: ResearchSource) {
    selectedId = selectedId === source.id ? null : source.id;
    const url = new URL(location.href);
    if (selectedId) url.searchParams.set("source", selectedId);
    else url.searchParams.delete("source");
    history.replaceState(null, "", url);
  }

  function clearFilters() {
    query = "";
    statusFilter = "all";
    typeFilter = "all";
    archiveFilter = "all";
    topicFilter = "all";
    selectedId = null;
    history.replaceState(null, "", location.pathname);
  }

  function formattedCitation(source: ResearchSource) {
    const locator = source.doi ? `https://doi.org/${source.doi}` : source.url;
    return `${source.authors.join(", ")}. “${source.title}.” ${source.publication}, ${source.year}. ${locator}`;
  }

  async function copyCitation(source: ResearchSource) {
    await navigator.clipboard.writeText(formattedCitation(source));
    copiedKey = source.citationKey;
    window.setTimeout(() => {
      if (copiedKey === source.citationKey) copiedKey = null;
    }, 1600);
  }

  function handleGlobalKey(event: KeyboardEvent) {
    if (event.metaKey || event.ctrlKey || event.altKey || event.defaultPrevented) return;
    const target = event.target as HTMLElement;
    const ownsText =
      target instanceof HTMLInputElement ||
      target instanceof HTMLTextAreaElement ||
      target instanceof HTMLSelectElement ||
      target.isContentEditable;
    if (ownsText) return;

    if (event.key === "1") {
      event.preventDefault();
      searchInput?.focus();
    } else if (event.key === "2") {
      event.preventDefault();
      clearFilters();
    } else if (event.key === "3") {
      event.preventDefault();
      document.querySelector("#method")?.scrollIntoView({ behavior: "smooth" });
    } else if (event.key === "4") {
      event.preventDefault();
      toggleTheme();
    }
  }
</script>

<svelte:window onkeydown={handleGlobalKey} />

<svelte:head>
  <title>HW Slicer Research Library</title>
  <meta
    name="description"
    content="Search the papers, specifications, and engineering decisions behind HW Slicer."
  />
  <meta property="og:title" content="HW Slicer Research Library" />
  <meta
    property="og:description"
    content="Evidence, limits, and explicit use decisions for an Apple Silicon FFF slicer."
  />
  <meta property="og:image" content="/og.png" />
  <meta property="og:type" content="website" />
  <meta name="twitter:card" content="summary_large_image" />
</svelte:head>

<header class="site-header">
  <a class="brand" href="#top" aria-label="HW Slicer Research home">
    <span class="brand-mark" aria-hidden="true">HW</span>
    <span>HW SLICER / RESEARCH</span>
  </a>

  <nav aria-label="Primary navigation">
    <a href="#library">LIBRARY</a>
    <a href="#method">METHOD</a>
    <a href="/references.bib" download>BIB</a>
  </nav>

  <button class="theme-control" type="button" onclick={toggleTheme}>
    {theme === "light" ? "DARK" : "LIGHT"}
  </button>
</header>

<main id="top">
  <section class="hero" aria-labelledby="page-title">
    <div>
      <p class="eyebrow">REVIEWED THROUGH {catalog?.reviewedThrough ?? "2026-07-29"}</p>
      <h1 id="page-title">Evidence before implementation.</h1>
    </div>
    <p class="hero-copy">
      Search the papers, specifications, and platform documentation behind HW Slicer.
      Every record states the finding, its limit, and whether the project will use it.
    </p>
    <dl class="hero-stats">
      <div>
        <dt>SOURCES</dt>
        <dd>{catalog?.sources.length ?? "—"}</dd>
      </div>
      <div>
        <dt>PDF SNAPSHOTS</dt>
        <dd>{catalog ? archivedCount : "—"}</dd>
      </div>
      <div>
        <dt>ADOPTED</dt>
        <dd>{catalog ? adoptedCount : "—"}</dd>
      </div>
    </dl>
  </section>

  <section id="library" class="library-shell" aria-labelledby="library-title">
    <aside class="filters" aria-label="Research filters">
      <div class="filter-heading">
        <div>
          <p class="eyebrow">FILTERS</p>
          <h2>Find a source</h2>
        </div>
        <button class="text-button" type="button" onclick={clearFilters}>CLEAR</button>
      </div>

      <label class="search-label" for="research-search">SEARCH TITLE, AUTHOR, TOPIC, OR USE</label>
      <div class="search-field">
        <span aria-hidden="true">⌕</span>
        <input
          id="research-search"
          bind:this={searchInput}
          bind:value={query}
          type="search"
          autocomplete="off"
          placeholder="robust predicates"
        />
        <kbd>1</kbd>
      </div>

      <fieldset>
        <legend>USE STATE</legend>
        <div class="filter-options">
          {#each statusOptions as option}
            <button
              type="button"
              class:active={statusFilter === option}
              aria-pressed={statusFilter === option}
              onclick={() => (statusFilter = option)}
            >
              {option}
            </button>
          {/each}
        </div>
      </fieldset>

      <fieldset>
        <legend>SOURCE TYPE</legend>
        <div class="filter-options">
          {#each typeOptions as option}
            <button
              type="button"
              class:active={typeFilter === option}
              aria-pressed={typeFilter === option}
              onclick={() => (typeFilter = option)}
            >
              {option}
            </button>
          {/each}
        </div>
      </fieldset>

      <fieldset>
        <legend>PDF SNAPSHOT</legend>
        <div class="filter-options">
          {#each ["all", "snapshot", "link"] as option}
            <button
              type="button"
              class:active={archiveFilter === option}
              aria-pressed={archiveFilter === option}
              onclick={() => (archiveFilter = option as typeof archiveFilter)}
            >
              {option === "link" ? "link only" : option}
            </button>
          {/each}
        </div>
      </fieldset>

      <label class="select-label" for="topic-filter">TOPIC</label>
      <select id="topic-filter" bind:value={topicFilter}>
        <option value="all">all topics</option>
        {#each topics as topic}
          <option value={topic}>{topic}</option>
        {/each}
      </select>

      <p class="filter-note">
        Local PDF files remain in the research workspace. This site links to their
        recorded source and never republishes them.
      </p>
    </aside>

    <div class="results">
      <div class="results-heading">
        <div>
          <p class="eyebrow">CATALOG</p>
          <h2 id="library-title">
            {filteredSources.length}
            {filteredSources.length === 1 ? "source" : "sources"}
          </h2>
        </div>
        <p>Sorted by {query.trim() ? "relevance" : "year"}</p>
      </div>

      {#if loadError}
        <div class="empty-state" role="alert">
          <p class="eyebrow">LOAD ERROR</p>
          <h3>The catalog is unavailable.</h3>
          <p>{loadError}</p>
        </div>
      {:else if !catalog}
        <div class="empty-state" aria-live="polite">
          <p class="eyebrow">INDEXING</p>
          <h3>Loading the research catalog.</h3>
        </div>
      {:else if filteredSources.length === 0}
        <div class="empty-state">
          <p class="eyebrow">NO MATCH</p>
          <h3>No source meets these filters.</h3>
          <button type="button" onclick={clearFilters}>RESET SEARCH</button>
        </div>
      {:else}
        <div class="source-list">
          {#each filteredSources as source (source.id)}
            <article class:selected={selectedId === source.id}>
              <button
                class="source-summary"
                type="button"
                aria-expanded={selectedId === source.id}
                aria-controls={`${source.id}-detail`}
                onclick={() => selectSource(source)}
              >
                <span class="source-index">{String(source.year).slice(2)}</span>
                <span class="source-main">
                  <span class="source-meta">
                    <span class={`status status-${source.status}`}>{source.status}</span>
                    <span>{source.type}</span>
                    <span>{source.pdf ? "PDF SNAPSHOT" : "SOURCE LINK"}</span>
                  </span>
                  <strong>{source.title}</strong>
                  <span class="authors">{source.authors.join(" · ")}</span>
                  <span class="summary-text">{source.summary}</span>
                  <span class="topic-list">
                    {#each source.topics.slice(0, 4) as topic}
                      <span>{topic}</span>
                    {/each}
                  </span>
                </span>
                <span class="expand-mark" aria-hidden="true">
                  {selectedId === source.id ? "−" : "+"}
                </span>
              </button>

              {#if selectedId === source.id}
                <div class="source-detail" id={`${source.id}-detail`}>
                  <div class="detail-column">
                    <p class="detail-label">WHAT THE SOURCE ESTABLISHES</p>
                    <ul>
                      {#each source.keyFindings as finding}
                        <li>{finding}</li>
                      {/each}
                    </ul>
                  </div>
                  <div class="detail-column usage-column">
                    <p class="detail-label">HW SLICER DECISION</p>
                    <p>{source.usage.decision}</p>
                    <p class="target-line">
                      TARGETS / {source.usage.targets.join(" · ")}
                    </p>
                  </div>
                  <div class="detail-column limitation-column">
                    <p class="detail-label">LIMITS</p>
                    <ul>
                      {#each source.limitations as limitation}
                        <li>{limitation}</li>
                      {/each}
                    </ul>
                    <p class="confidence">EVIDENCE CONFIDENCE / {source.confidence}</p>
                  </div>
                  <div class="citation-block">
                    <p>{formattedCitation(source)}</p>
                    <div class="source-actions">
                      <a href={source.pdf?.sourceUrl ?? source.url} target="_blank" rel="noreferrer">
                        {source.pdf ? "OPEN PDF SOURCE" : "OPEN SOURCE"}
                      </a>
                      <button type="button" onclick={() => copyCitation(source)}>
                        {copiedKey === source.citationKey ? "COPIED" : "COPY CITATION"}
                      </button>
                      <span>{source.citationKey}</span>
                    </div>
                    {#if source.pdf}
                      <p class="provenance">
                        SNAPSHOT / {source.pdf.provenance} / SHA-256
                        {source.pdf.sha256.slice(0, 12)}…
                      </p>
                    {/if}
                  </div>
                </div>
              {/if}
            </article>
          {/each}
        </div>
      {/if}
    </div>
  </section>

  <section id="method" class="method" aria-labelledby="method-title">
    <div>
      <p class="eyebrow">RESEARCH METHOD</p>
      <h2 id="method-title">A source becomes useful when its boundary is explicit.</h2>
    </div>
    <div class="method-grid">
      <article>
        <span>01</span>
        <h3>Verify identity</h3>
        <p>
          Resolve the title, authors, venue, version, pages, DOI, and source URL
          against primary publication metadata.
        </p>
      </article>
      <article>
        <span>02</span>
        <h3>Extract mechanics</h3>
        <p>
          Record the data transformation, execution model, measured result, and
          assumptions that make the result hold.
        </p>
      </article>
      <article>
        <span>03</span>
        <h3>State the limit</h3>
        <p>
          Separate what the source proves from printer calibration, Apple GPU
          behavior, and project decisions that still need tests.
        </p>
      </article>
      <article>
        <span>04</span>
        <h3>Bind a decision</h3>
        <p>
          Mark the source adopted, candidate, background, rejected, or unreviewed,
          then name the implementation target.
        </p>
      </article>
    </div>
    <div class="method-footer">
      <p>
        The catalog checksum validates the reviewed file. Reproduction and project
        benchmarks validate the method.
      </p>
      <a href="/references.bib" download>DOWNLOAD BIBLATEX</a>
    </div>
  </section>
</main>

<footer>
  <p>HW SLICER RESEARCH / SCHEMA 1</p>
  <p>20 VERIFIED RECORDS / 15 PDF SNAPSHOTS</p>
</footer>

<div class="action-bar" aria-label="Keyboard actions">
  <button type="button" onclick={() => searchInput?.focus()}><kbd>01</kbd> SEARCH</button>
  <button type="button" onclick={clearFilters}><kbd>02</kbd> CLEAR</button>
  <button
    type="button"
    onclick={() => document.querySelector("#method")?.scrollIntoView({ behavior: "smooth" })}
  >
    <kbd>03</kbd> METHOD
  </button>
  <button type="button" onclick={toggleTheme}><kbd>04</kbd> THEME</button>
</div>
