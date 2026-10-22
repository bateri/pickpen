/**
 * The command line that does again, with no person, what the person did in the view: the
 * query as `--where`, the order as `--sort`, and the output as it was shaped. Run in a
 * script or by cron, it writes the rows the query matches, which are the rows the person
 * sent when they sent every row the query showed.
 */

export interface Recipe {
  /** `--input` as the person gave it; the shape read from the input needs no flag. */
  input?: string;
  where: string;
  sort?: { column: string; descending: boolean };
  field?: string[];
  format?: string;
  output?: string;
}

/** A word as a POSIX shell reads it back: bare when it is safe, in single quotes otherwise. */
export function shellQuote(word: string): string {
  if (word !== "" && /^[A-Za-z0-9_@%+=:,./-]+$/.test(word)) return word;
  return `'${word.replace(/'/g, `'\\''`)}'`;
}

export function commandLine(recipe: Recipe): string {
  const words = ["pickpen"];
  if (recipe.input) words.push("--input", recipe.input);
  words.push("--where", shellQuote(recipe.where.trim() === "" ? "" : recipe.where.trim()));
  if (recipe.sort) {
    words.push("--sort", shellQuote(`${recipe.sort.descending ? "-" : ""}${recipe.sort.column}`));
  }
  if (recipe.field && recipe.field.length > 0)
    words.push("--field", shellQuote(recipe.field.join(",")));
  else if (recipe.format) words.push("--format", shellQuote(recipe.format));
  else if (recipe.output) words.push("--output", recipe.output);
  return words.join(" ");
}
