// Serves the static pages; "/" maps to index.html (html_handling is "none" so /privacy.html etc. stay as-is).
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "") url.pathname = "/index.html";
    return env.ASSETS.fetch(new Request(url, request));
  },
};
