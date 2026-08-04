import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";

export const SITE_URL = "https://muhammad-fiaz.github.io/sqlite.zig";
export const SITE_NAME = "sqlite.zig";
export const SITE_DESCRIPTION =
  "A fully native, zero-dependency SQLite-compatible database engine written entirely in Zig. Pure Zig storage engine, SQL parser, bytecode VM, typed DSL query builder, WAL journaling, and cross-platform support.";

export const GA_ID = "G-6BVYCRK57P";
export const GTM_ID = "GTM-P4M9T8ZR";
export const ADSENSE_CLIENT_ID = "ca-pub-2040560600290490";

export const KEYWORDS =
  "zig, sqlite, database, sql, btree, storage engine, query builder, dsl, wal, transactions, prepared statements, joins, cte, triggers, views, cross-platform, zero-dependency";

export default defineConfig({
  lang: "en-US",
  title: SITE_NAME,
  titleTemplate: `:title | ${SITE_NAME}`,
  description: SITE_DESCRIPTION,
  base: "/sqlite.zig/",
  lastUpdated: true,
  cleanUrls: false,

  sitemap: {
    hostname: SITE_URL,
  },

  vite: {
    plugins: [llmstxt()],
  },

  head: [
    ["meta", { name: "title", content: SITE_NAME }],
    ["meta", { name: "description", content: SITE_DESCRIPTION }],
    ["meta", { name: "keywords", content: KEYWORDS }],
    ["meta", { name: "author", content: "Muhammad Fiaz" }],
    ["meta", { name: "robots", content: "index, follow" }],
    ["meta", { name: "language", content: "English" }],
    ["meta", { name: "revisit-after", content: "7 days" }],

    // Open Graph
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:url", content: SITE_URL }],
    ["meta", { property: "og:title", content: "SQLite Database Engine for Zig | sqlite.zig" }],
    ["meta", { property: "og:description", content: SITE_DESCRIPTION }],
    ["meta", { property: "og:image", content: `${SITE_URL}/cover.png` }],
    ["meta", { property: "og:image:width", content: "1200" }],
    ["meta", { property: "og:image:height", content: "630" }],
    ["meta", { property: "og:image:alt", content: "sqlite.zig — SQLite Database Engine for Zig" }],
    ["meta", { property: "og:site_name", content: SITE_NAME }],
    ["meta", { property: "og:locale", content: "en_US" }],

    // Twitter Card
    ["meta", { name: "twitter:card", content: "summary_large_image" }],
    ["meta", { name: "twitter:url", content: SITE_URL }],
    ["meta", { name: "twitter:title", content: "SQLite Database Engine for Zig | sqlite.zig" }],
    ["meta", { name: "twitter:description", content: SITE_DESCRIPTION }],
    ["meta", { name: "twitter:image", content: `${SITE_URL}/cover.png` }],
    ["meta", { name: "twitter:image:alt", content: "sqlite.zig — SQLite Database Engine for Zig" }],
    ["meta", { name: "twitter:site", content: "@muhammadfiaz_" }],
    ["meta", { name: "twitter:creator", content: "@muhammadfiaz_" }],

    // Canonical
    ["link", { rel: "canonical", href: SITE_URL }],

    // Favicon
    ["link", { rel: "icon", href: "/sqlite.zig/favicon.png", type: "image/png" }],
    ["link", { rel: "apple-touch-icon", href: "/sqlite.zig/favicon.png" }],
    ["link", { rel: "manifest", href: "/sqlite.zig/site.webmanifest" }],

    // Theme
    ["meta", { name: "theme-color", content: "#76b900" }],
    ["meta", { name: "msapplication-TileColor", content: "#76b900" }],

    // Google Analytics
    ["script", { async: "", src: `https://www.googletagmanager.com/gtag/js?id=${GA_ID}` }],
    [
      "script",
      {},
      `window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','${GA_ID}');`,
    ],

    // Google Tag Manager
    [
      "script",
      {},
      `(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src='https://www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);})(window,document,'script','dataLayer','${GTM_ID}');`,
    ],

    // AdSense
    [
      "script",
      {
        async: "",
        src: `https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=${ADSENSE_CLIENT_ID}`,
        crossorigin: "anonymous",
      },
    ],
  ],

  ignoreDeadLinks: [/.*\.zig$/],

  transformPageData(pageData: any) {
    const pageTitle = pageData.title || SITE_NAME;
    const pageDescription = pageData.description || SITE_DESCRIPTION;
    const normalizedPath = pageData.relativePath
      .replace(/\.md$/, "")
      .replace(/(^|\/)index$/, "$1")
      .replace(/\/$/, "");
    const canonicalUrl =
      normalizedPath.length > 0 ? `${SITE_URL}/${normalizedPath}` : SITE_URL;

    pageData.frontmatter.head ??= [];
    pageData.frontmatter.head.push(
      ["link", { rel: "canonical", href: canonicalUrl }],
      ["meta", { property: "og:title", content: `${pageTitle} | ${SITE_NAME}` }],
      ["meta", { property: "og:url", content: canonicalUrl }],
      ["meta", { property: "og:image", content: `${SITE_URL}/cover.png` }]
    );

    if (pageData.frontmatter.description) {
      pageData.frontmatter.head.push(
        ["meta", { property: "og:description", content: pageData.frontmatter.description }],
        ["meta", { name: "description", content: pageData.frontmatter.description }]
      );
    }

    const isHome = pageData.relativePath === "index.md";
    const lastUpdated = pageData.lastUpdated
      ? new Date(pageData.lastUpdated).toISOString()
      : new Date().toISOString();

    const graph: any[] = [];

    if (isHome) {
      graph.push({
        "@type": "WebSite",
        name: SITE_NAME,
        url: SITE_URL,
        description: SITE_DESCRIPTION,
        author: { "@type": "Person", name: "Muhammad Fiaz", url: "https://github.com/muhammad-fiaz" },
      });
    }

    const authorSchema = {
      "@type": "Person",
      name: "Muhammad Fiaz",
      url: "https://muhammadfiaz.com",
      sameAs: [
        "https://github.com/muhammad-fiaz",
        "https://www.linkedin.com/in/muhammad-fiaz-",
        "https://x.com/muhammadfiaz_",
      ],
    };

    const primarySchema: Record<string, any> = {
      "@type": isHome ? "SoftwareApplication" : "TechArticle",
      name: isHome ? SITE_NAME : pageTitle,
      description: pageDescription,
      url: canonicalUrl,
      image: `${SITE_URL}/cover.png`,
      author: authorSchema,
      publisher: {
        "@type": "Organization",
        name: SITE_NAME,
        url: SITE_URL,
      },
    };

    if (isHome) {
      Object.assign(primarySchema, {
        applicationCategory: "DeveloperApplication",
        operatingSystem: "Cross-platform",
        programmingLanguage: "Zig",
        offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
        downloadUrl: "https://github.com/muhammad-fiaz/sqlite.zig",
        softwareVersion: "0.0.1",
        license: "https://opensource.org/licenses/MIT",
      });
    } else {
      const pathParts = pageData.relativePath.split("/");
      const section =
        pathParts.length > 1
          ? pathParts[0].charAt(0).toUpperCase() + pathParts[0].slice(1)
          : "Documentation";
      Object.assign(primarySchema, {
        headline: pageTitle,
        articleSection: section,
        mainEntityOfPage: { "@type": "WebPage", "@id": canonicalUrl },
        datePublished: "2026-01-01T00:00:00Z",
        dateModified: lastUpdated,
      });
    }
    graph.push(primarySchema);

    // BreadcrumbList
    const breadcrumbs: any[] = [{ "@type": "ListItem", position: 1, name: "Home", item: SITE_URL }];
    if (!isHome) {
      const pathParts = pageData.relativePath.replace(/\.md$/, "").split("/");
      let currentPath = SITE_URL;
      pathParts.forEach((part: string, index: number) => {
        currentPath += `/${part}`;
        const name = part.split("-").map((s: string) => s.charAt(0).toUpperCase() + s.slice(1)).join(" ");
        breadcrumbs.push({
          "@type": "ListItem",
          position: index + 2,
          name,
          item: index === pathParts.length - 1 ? canonicalUrl : currentPath,
        });
      });
    }
    graph.push({ "@type": "BreadcrumbList", itemListElement: breadcrumbs });

    pageData.frontmatter.head.push([
      "script",
      { type: "application/ld+json" },
      JSON.stringify({ "@context": "https://schema.org", "@graph": graph }),
    ]);
  },

  themeConfig: {
    siteTitle: "sqlite.zig",

    nav: [
      { text: "Home", link: "/" },
      { text: "Guide", link: "/guide/getting-started" },
      { text: "API", link: "/api/" },
      { text: "Examples", link: "/examples/" },
      { text: "Projects", link: "/guide/related-projects" },
      {
        text: "Support",
        items: [
          { text: "Sponsor", link: "https://github.com/sponsors/muhammad-fiaz" },
          { text: "Donate", link: "https://pay.muhammadfiaz.com" },
        ],
      },
      { text: "GitHub", link: "https://github.com/muhammad-fiaz/sqlite.zig" },
    ],

    sidebar: {
      "/guide/": [
        {
          text: "Introduction",
          items: [
            { text: "Getting Started", link: "/guide/getting-started" },
            { text: "Installation", link: "/guide/installation" },
          ],
        },
        {
          text: "Core Concepts",
          items: [
            { text: "SQL Engine", link: "/guide/sql-engine" },
            { text: "DSL Query Builder", link: "/guide/dsl-query-builder" },
            { text: "Transactions", link: "/guide/transactions" },
            { text: "Foreign Keys", link: "/guide/foreign-keys" },
            { text: "Views & Triggers", link: "/guide/views-triggers" },
            { text: "CTEs & Subqueries", link: "/guide/ctes-subqueries" },
            { text: "Related Projects", link: "/guide/related-projects" },
          ],
        },
      ],
      "/api/": [
        {
          text: "API Reference",
          items: [
            { text: "Overview", link: "/api/" },
            { text: "Connection", link: "/api/connection" },
            { text: "DSL", link: "/api/dsl" },
            { text: "SQL", link: "/api/sql" },
            { text: "Storage", link: "/api/storage" },
            { text: "Catalog", link: "/api/catalog" },
          ],
        },
      ],
      "/examples/": [
        {
          text: "Examples",
          items: [
            { text: "All Examples", link: "/examples/" },
            { text: "01 — Open & Exec", link: "/examples/01-open-and-exec" },
            { text: "02 — Prepared Statement", link: "/examples/02-prepared-statement" },
            { text: "03 — Transactions", link: "/examples/03-transactions" },
            { text: "04 — DSL Query Builder", link: "/examples/04-dsl-query-builder" },
            { text: "05 — Migrations", link: "/examples/05-migrations" },
            { text: "06 — Error Handling", link: "/examples/06-error-handling" },
            { text: "07 — Python Interop", link: "/examples/07-python-interop" },
            { text: "08 — Repair Legacy", link: "/examples/08-repair-legacy" },
            { text: "09 — DSL CRUD", link: "/examples/09-dsl-crud" },
            { text: "10 — DSL Advanced", link: "/examples/10-dsl-advanced" },
            { text: "11 — Keys & Joins", link: "/examples/11-keys-and-joins" },
            { text: "12 — Complex Queries", link: "/examples/12-complex-queries" },
            { text: "13 — Edge Cases", link: "/examples/13-edge-cases" },
            { text: "14 — Select Projections", link: "/examples/14-dsl-select-projections" },
            { text: "15 — Raw & DSL Interop", link: "/examples/15-raw-dsl-interoperability" },
            { text: "16 — Predicates & Pagination", link: "/examples/16-dsl-predicates-pagination" },
            { text: "17 — Persistence", link: "/examples/17-persistence-reopen" },
            { text: "18 — Schema Lifecycle", link: "/examples/18-schema-lifecycle" },
            { text: "19 — Prepared Parameters", link: "/examples/19-prepared-parameter" },
            { text: "20 — Scalar Functions", link: "/examples/20-scalar-functions" },
            { text: "21 — Indexed Queries", link: "/examples/21-indexed-queries" },
            { text: "22 — Views", link: "/examples/22-views" },
            { text: "23 — Triggers", link: "/examples/23-triggers" },
            { text: "24 — CTEs", link: "/examples/24-ctes" },
            { text: "25 — Subqueries", link: "/examples/25-subqueries" },
            { text: "26 — FK Actions", link: "/examples/26-foreign-key-actions" },
            { text: "27 — Composite Unique", link: "/examples/27-composite-unique" },
            { text: "28 — FK Update Actions", link: "/examples/28-fk-update-actions" },
            { text: "29 — Multiple CTEs", link: "/examples/29-multiple-ctes" },
            { text: "30 — Composite Constraints", link: "/examples/30-composite-constraints" },
            { text: "31 — Composite FKs", link: "/examples/31-composite-foreign-keys" },
            { text: "32 — Recursive CTEs", link: "/examples/32-recursive-ctes" },
          ],
        },
      ],
    },

    socialLinks: [{ icon: "github", link: "https://github.com/muhammad-fiaz/sqlite.zig" }],

    footer: {
      message: "Released under the MIT License.",
      copyright: "Copyright \u00a9 2026 Muhammad Fiaz",
    },

    search: { provider: "local" },

    editLink: {
      pattern: "https://github.com/muhammad-fiaz/sqlite.zig/edit/main/docs/:path",
      text: "Edit this page on GitHub",
    },

    lastUpdated: {
      text: "Last updated",
      formatOptions: { dateStyle: "medium", timeStyle: "short" },
    },
  },
});
