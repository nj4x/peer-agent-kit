// cline-sr decodeURIComponent()s the whole URI before URL-parsing it, so the
// prompt must arrive double-encoded. Uri.from keeps this query verbatim and
// Uri.toString() adds the second layer by encoding '%' as '%25'.
export function buildTaskUriComponents(scheme: string, prompt: string) {
  return {
    scheme,
    authority: "cline-sr.cline-sr",
    path: "/task",
    query: `prompt=${encodeURIComponent(prompt)}`,
  };
}
