// Written by tools/icon.mjs; change the shapes there and run it again.

import type { Icon } from "@modelcontextprotocol/server";

/**
 * pickpen's icon, the mark its view shows, for a dark ground and a light one (MCP's `theme`),
 * 32 and 64 pixels a side, as PNGs in `data:` URIs: a terminal draws an icon only from the
 * bytes it is given, and never fetches one.
 */
export const ICONS: Icon[] = [
  {
    src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAA0klEQVR42mOIObGEYSAxw2BygEvMiSWzY04smY+EK2JOLOGhhwMMYk4s+R1zYsl/LHg6PRyQgMNyEN6PpEEn5sSS63jUEoN/Q0OXhRwHbKbQcmQcMCQdQLMoGPBEOODZcLQkBGGRmBNL9KHpAYZVYImF1g7gizmxxDvmxBJfLFiXHg6QxWE5CFsiaRCKObEkLObEkjQSsF/MiSUc1HKAB4mWw7DpsHEAzaJgwBPhgGfD0ZJwtE1IjwbJ65gTS0IodQClTbLXQ94BNIuC0TbhyC0JAQH6Le2+pr3dAAAAAElFTkSuQmCC",
    mimeType: "image/png",
    sizes: ["32x32"],
    theme: "dark",
  },
  {
    src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAABgUlEQVR42u2asUoDQRCGD1EQNCBqpwSLFBaCAatgI2ITUPvglGLlI1j4Bj6ARZp5gxSWKWzmDSwsLHwAixQp9Q6yTcgel8O7WzZf8XPFwe39H8zszO4kYpqsshIAAAAAPh2L6UWODmMFkJn7FNPfAnoX005MAE7EdFLQvNO3mO7EAmC4pHmnx1gAjEsCePUssJ4+n8X0q+R3/0s/s3/crwrA0APgrWHj8/qYD9cqAVwHZt7pqS4AL4ECGAOAECAJsg1SCFEK0wzRDnMgAgAAACDv5baY7uVoM1YAmblLMb0poHMx3YoJQEtM+wXNO12J6UYsALpLmnc6igVArySAU88Ca2J6JqYDMX2oQPdieps2OgdNA+h6FuhXZHwRiHZoANo1mXe6Cw1Ar2YAmXYBQAiQBNkGKYQohWmGaIc5EAEAAADAxQhXY1yOMie4inOC07QBG81yWG0AQhyRmRSBEPuQ1KhJACGMyU0BQAiQBNkGKYQohWmGaIc5EAEAAACwSH/OurphtwuiFAAAAABJRU5ErkJggg==",
    mimeType: "image/png",
    sizes: ["64x64"],
    theme: "dark",
  },
  {
    src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAz0lEQVR42mPgK4thGEjMMJgc4MJXFjObryxmPhKu4CuL4aGHAwz4ymJ+85XF/MeCp9PDAQk4LAfh/UgadPjKYq7jUUsM/g0NXRZyHLCZQsuRccCQdADNomDAE+GAZ8PRkhCERfjKYvSh6QGGVWCJhdYO4OMri/HmK4vxxYJ16eEAWRyWg7AlkgYhvrKYML6ymDQSsB9fWQwHtRzgQaLlMGw6bBxAsygY8EQ44NlwtCQcbRPSo0Hymq8sJoRSB1DaJHs95B1AsygYbROO3JIQAGNYjbEK3Cs+AAAAAElFTkSuQmCC",
    mimeType: "image/png",
    sizes: ["32x32"],
    theme: "light",
  },
  {
    src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAABgElEQVR42u2asUoDQRCGD1EQ1EHUTgkWFhaCAatgI2IT0PTilCGV9VQWvoEPYJGHSGGZwoewsLDwASxSpNQ7yDYhe1wO727ZfMXPFQe3938wszO7k4hpsspKAAAAAPh0KqZXOTqKFUBm7lNMfwvoXUxPYgJwJqaTguadvsV0NxYAwyXNOz3GAmBcEsCrZ4H19Pkspl8lv/tf+pn940FVAIYeAG8NG5/Xx3y4VgngNjDzTk91AXgJFMAYAIQASZBtkEKIUphmiHaYAxEAAAAAeS+3xXQ/R5uxAsjMXYvpXQFdiulWTAB2xLRb0LzTjZhuxAKgvaR5p+NYAHRKAjj3LLAmphdiei+mgwrUF9Ne2ugcNg2g7VmgW5HxRSBaoQFo1WTe6SE0AJ2aAWTaAwAhQBJkG6QQohSmGaId5kAEAAAAABcjXI1xOcqc4CrOCU7TBmw0y2G1AQhxRGZSBELsQ1KjJgGEMCY3BQAhQBJkG6QQohSmGaId5kAEAAAAwCL9AeF9OY9JhpR8AAAAAElFTkSuQmCC",
    mimeType: "image/png",
    sizes: ["64x64"],
    theme: "light",
  },
];
