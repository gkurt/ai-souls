---
packages:
  ai-souls: patch
---

## The bar has no border around it any more

macOS was drawing a window shadow behind the banner, and because the bar
is see-through the shadow showed through its own edges as a black rim on
all four sides. The soft edges now dissolve into whatever is underneath
instead of stopping at a line.
