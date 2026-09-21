import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";

export const SITE_ORIGIN = "https://muhammad-fiaz.github.io";
export const SITE_BASE = "/sqlite.zig";
export const SITE_URL = `${SITE_ORIGIN}${SITE_BASE}`;

export const ICON_ICO = `${SITE_BASE}/favicon.ico`;
export const ICON_16 = `${SITE_BASE}/favicon-16x16.png`;
export const ICON_32 = `${SITE_BASE}/favicon-32x32.png`;
export const ICON_APPLE = `${SITE_BASE}/apple-touch-icon.png`;
export const ICON_192 = `${SITE_BASE}/android-chrome-192x192.png`;
export const ICON_512 = `${SITE_BASE}/android-chrome-512x512.png`;
export const LOGO = `${SITE_BASE}/logo.png`;
export const OG_IMAGE = `${SITE_URL}/logo.png`;
export const OG_IMAGE_WIDTH = "1536";
export const OG_IMAGE_HEIGHT = "1024";
export const SITE_NAME = "sqlite.zig";
export const SITE_TAGLINE = "Native SQLite-Compatible Database Engine in Zig";
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
    hostname: SITE_ORIGIN,
    transformItems: (items) =>
      items.map((item) => ({
        ...item,
        url: `${SITE_BASE}${item.url.startsWith("/") ? item.url : `/${item.url}`}`,
      })),
  },

  vite: {
    plugins: [llmstxt()],
  },

  head: [
    // Basic Meta
    ["meta", { name: "description", content: SITE_DESCRIPTION }],
    ["meta", { name: "keywords", content: KEYWORDS }],
    ["meta", { name: "author", content: "Muhammad Fiaz" }],
    ["meta", { name: "publisher", content: "Muhammad Fiaz" }],
    ["meta", { name: "robots", content: "index, follow" }],
    ["meta", { name: "language", content: "English" }],
    ["meta", { name: "revisit-after", content: "7 days" }],
    ["meta", { name: "application-name", content: SITE_NAME }],
    ["meta", { name: "apple-mobile-web-app-title", content: SITE_NAME }],
    ["meta", { name: "apple-mobile-web-app-capable", content: "yes" }],
    ["meta", { name: "apple-mobile-web-app-status-bar-style", content: "black-translucent" }],
    ["meta", { name: "mobile-web-app-capable", content: "yes" }],

    // Open Graph
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:url", content: SITE_URL }],
    ["meta", { property: "og:title", content: `${SITE_TAGLINE} | ${SITE_NAME}` }],
    ["meta", { property: "og:description", content: SITE_DESCRIPTION }],
    ["meta", { property: "og:image", content: OG_IMAGE }],
    ["meta", { property: "og:image:width", content: OG_IMAGE_WIDTH }],
    ["meta", { property: "og:image:height", content: OG_IMAGE_HEIGHT }],
    ["meta", { property: "og:image:type", content: "image/png" }],
    ["meta", { property: "og:image:alt", content: `${SITE_TAGLINE} | ${SITE_NAME}` }],
    ["meta", { property: "og:site_name", content: SITE_NAME }],
    ["meta", { property: "og:locale", content: "en_US" }],

    // Twitter Card
    ["meta", { name: "twitter:card", content: "summary_large_image" }],
    ["meta", { name: "twitter:url", content: SITE_URL }],
    ["meta", { name: "twitter:title", content: `${SITE_TAGLINE} | ${SITE_NAME}` }],
    ["meta", { name: "twitter:description", content: SITE_DESCRIPTION }],
    ["meta", { name: "twitter:image", content: OG_IMAGE }],
    ["meta", { name: "twitter:image:alt", content: `${SITE_TAGLINE} | ${SITE_NAME}` }],
    ["meta", { name: "twitter:site", content: "@muhammadfiaz_" }],
    ["meta", { name: "twitter:creator", content: "@muhammadfiaz_" }],

    // Microsoft
    ["meta", { name: "msapplication-TileColor", content: "#76b900" }],
    ["meta", { name: "msapplication-TileImage", content: ICON_192 }],
    ["meta", { name: "msapplication-tooltip", content: SITE_TAGLINE }],

    // Canonical
    ["link", { rel: "canonical", href: SITE_URL }],

    // Favicons & icons
    ["link", { rel: "icon", href: ICON_ICO, type: "image/x-icon" }],
    ["link", { rel: "icon", href: ICON_32, type: "image/png", sizes: "32x32" }],
    ["link", { rel: "icon", href: ICON_16, type: "image/png", sizes: "16x16" }],
    ["link", { rel: "apple-touch-icon", href: ICON_APPLE, sizes: "180x180" }],
    ["link", { rel: "manifest", href: "/sqlite.zig/site.webmanifest" }],

    // Theme
    ["meta", { name: "theme-color", content: "#76b900" }],

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

  transformPageData(pageData: any) {
    const pageTitle = pageData.title || SITE_NAME;
    const pageDescription = pageData.description || SITE_DESCRIPTION;
    const normalizedPath = pageData.relativePath
      .replace(/\.md$/, "")
      .replace(/(^|\/)index$/, "$1")
      .replace(/\/$/, "");
    const canonicalUrl =
      normalizedPath.length > 0 ? `${SITE_URL}/${normalizedPath}` : SITE_URL;

    const isHome = pageData.relativePath === "index.md";
    const fullTitle = isHome ? `${SITE_TAGLINE} | ${SITE_NAME}` : `${pageTitle} | ${SITE_NAME}`;

    const lastUpdated = pageData.lastUpdated
      ? new Date(pageData.lastUpdated).toISOString()
      : new Date().toISOString();

    pageData.frontmatter.head ??= [];
    pageData.frontmatter.head.push(
      ["meta", { name: "description", content: pageDescription }],
      ["link", { rel: "canonical", href: canonicalUrl }],
      ["meta", { property: "og:type", content: isHome ? "website" : "article" }],
      ["meta", { property: "og:title", content: fullTitle }],
      ["meta", { property: "og:description", content: pageDescription }],
      ["meta", { property: "og:url", content: canonicalUrl }],
      ["meta", { property: "og:image", content: OG_IMAGE }],
      ["meta", { property: "og:image:width", content: OG_IMAGE_WIDTH }],
      ["meta", { property: "og:image:height", content: OG_IMAGE_HEIGHT }],
      ["meta", { property: "og:site_name", content: SITE_NAME }],
      ["meta", { property: "og:locale", content: "en_US" }],
      ["meta", { name: "twitter:card", content: "summary_large_image" }],
      ["meta", { name: "twitter:title", content: fullTitle }],
      ["meta", { name: "twitter:description", content: pageDescription }],
    ["meta", { name: "twitter:image", content: OG_IMAGE }],
    );

    // JSON-LD structured data
    const graph: any[] = [];

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

    const publisherSchema = {
      "@type": "Organization",
      name: SITE_NAME,
      url: SITE_URL,
      logo: {
        "@type": "ImageObject",
        url: OG_IMAGE,
        width: 1536,
        height: 1024,
      },
    };

    if (isHome) {
      graph.push({
        "@type": "WebSite",
        name: SITE_NAME,
        url: SITE_URL,
        description: SITE_DESCRIPTION,
        author: authorSchema,
        publisher: publisherSchema,
        image: OG_IMAGE,
        datePublished: "2026-01-01T00:00:00Z",
        dateModified: lastUpdated,
      });
    }

    const primarySchema: Record<string, any> = {
      "@type": isHome ? "SoftwareApplication" : "TechArticle",
      name: isHome ? SITE_NAME : pageTitle,
      description: pageDescription,
      url: canonicalUrl,
      image: OG_IMAGE,
      author: authorSchema,
      publisher: publisherSchema,
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
        datePublished: "2026-01-01T00:00:00Z",
        dateModified: lastUpdated,
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
    siteTitle: SITE_NAME,

    nav: [
      { text: "Home", link: "/" },
      { text: "Guide", link: "/guide/getting-started" },
      { text: "API", link: "/api/" },
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
            { text: "Aggregates", link: "/guide/aggregates" },
            { text: "Conflict Handling", link: "/guide/conflict-handling" },
            { text: "Insert...Select", link: "/guide/insert-select" },
            { text: "Subqueries", link: "/guide/subqueries" },
            { text: "Update...From", link: "/guide/update-from" },
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
            { text: "B-Tree", link: "/api/btree" },
            { text: "VM", link: "/api/vm" },
            { text: "Planner", link: "/api/planner" },
            { text: "Storage", link: "/api/storage" },
            { text: "Format", link: "/api/format" },
            { text: "Catalog", link: "/api/catalog" },
            { text: "Transaction", link: "/api/transaction" },
            { text: "Migration", link: "/api/migration" },
            { text: "Errors", link: "/api/errors" },
            { text: "Version", link: "/api/version" },
            { text: "Compatibility", link: "/api/compatibility" },
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
