# Use case — the bathroom-designer scenario

This is the full story behind the demo. It motivates every architectural choice in the codebase.

---

## Persona

**Priya**, a senior interior designer at a boutique firm in Mumbai. She has 12 years of experience, works across residential and hospitality, and her clients expect:

- A **visual interpretation** of the brief, on the call, while the conversation is happening.
- **Real, available, locally-sourced products** — not generic stock photography, not Pinterest collages, not "AI hallucinations".
- A **rationale** for every product choice (material, finish, brand reliability, lead time).

She works primarily with two Indian brands: **Jaguar** (mid-to-premium bathroom fittings) and **Parryware** (mass-market to premium sanitaryware). She keeps their catalog PDFs open in tabs all day.

---

## Pain points before the accelerator

| Activity | Time | Annoyance |
|---|---|---|
| Sketch a mood-board for one room | 25-40 min | Manual Photoshop / Canva work; nothing is grounded in real SKUs |
| Find the right Jaguar / Parryware SKU | 10-20 min | Catalog PDFs are 300 pages each; full-text search is useless on image-heavy PDFs |
| Justify a product on a call | live | Has to flip to the catalog tab and read out the description |
| Avoid "AI hallucination" | constant | Generic text-to-image tools invent products that don't exist; clients have been burnt |

---

## The accelerator turn

> Priya is on a Teams call with a client briefing a master ensuite. She types into the **Design Studio**:
>
> *"Design a luxury marble ensuite featuring a Jaguar single-lever basin mixer in brushed gold, a Parryware concealed thermostatic shower, and book-matched Calacatta marble walls with warm uplighting."*
>
> She ticks ? **Jaguar** ? **Parryware** and hits **Generate**.

**Under 60 seconds later** the UI shows:

1. **A photoreal 1024×1024 bathroom render** from **MAI-Image-2** that interprets her brief. *Inspiration, not a quote.*
2. **A markdown narrative** explaining the design choices, naming each catalog product and reflecting the requested style hints ("brushed gold", "Calacatta", "warm uplighting").
3. **A "Fittings you may like" gallery** of the *actual* products surfaced by **Foundry IQ** semantic search over the Jaguar and Parryware catalogs. Each card shows:
    - the rendered PDF page that cited the product (clickable, opens that exact page),
    - the brand, SKU, page number,
    - a relevance score.
4. **A live agent-trace panel** (Foundry-Playground-style) that streamed every step over SSE as it happened — Priya can show the client *exactly* how the recommendation was made.

The narrative is **honest about its boundaries**: MAI provides *inspiration*; Foundry IQ provides *shoppable discovery*. Priya tells the client "this image is the vibe; these four product cards are the actual SKUs we'd specify."

---

## Why this matters

Most AI-image demos look impressive in isolation but **die on contact with a procurement workflow** because the products in the image don't exist. Most RAG demos look correct but **die on contact with a creative brief** because grounded retrieval can't paint a scene.

The accelerator's thesis is that you need **both**, separated cleanly:

- **MAI-Image-2** for *visual interpretation* — generative, photoreal, deliberately not constrained to a SKU list.
- **Foundry IQ (AI Search semantic + Document Intelligence Layout)** for *shoppable discovery* — strictly grounded in the brand catalogs you uploaded.

The UI makes this separation obvious. The architecture makes it cheap. The orchestrator makes it fast.

---

## Acceptance criteria for a "good" turn

A turn is considered successful if **all** of these are true:

- [x] Image returned within 60 s, 1024×1024, no obvious anatomy/typography failures.
- [x] At least one catalog product per ticked brand on the cards.
- [x] No "product" appears on a card that wasn't in the retrieve result (no hallucinated cards).
- [x] Narrative names every product on a card by its catalog name.
- [x] Every card's catalog page raster opens to the *exact* page that cited the product.
- [x] Agent trace shows all four phases (PLAN, RETRIEVE, COMPOSE, RENDER), each green.

---

## What's deliberately out of scope

- **Pricing / availability** — the catalogs don't carry real-time price; this is a creative tool, not a quoting tool.
- **3D / room layout** — we render a hero shot, not a floor-plan.
- **Multi-turn refinement** — each brief is a fresh turn; conversational refinement is a follow-up feature, not a v1.
- **Non-bath verticals** — the scenario is bathroom design; the *pattern* (per-brand catalog + MAI inspiration) generalises but the prompts and indexes don't.
