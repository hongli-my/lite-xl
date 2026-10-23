#include "api.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * tokenizer_c — merged Lua-pattern matcher for syntax highlighting.
 *
 * data/core/tokenizer.lua walks each line position and, for every position,
 * tries each syntax pattern in order with ufind("^" .. pattern). That is
 * O(positions x patterns) Lua-implemented pattern calls and dominates the
 * cost of highlighting large files.
 *
 * This module compiles Lua pattern strings into NFA programs and answers
 * "which pattern matches here, and how far" with a single priority-ordered
 * parallel simulation (Pike VM, the same design as RE2's): all patterns run
 * simultaneously over the text and the highest-priority (lowest index)
 * match wins, which reproduces the original first-match-in-pattern-order
 * loop, including greedy/lazy quantifier preferences.
 *
 * Character semantics intentionally mirror the vendored luautf8 matcher in
 * src/api/utf8.c, whose helpers this file reuses:
 *   - matching operates on decoded codepoints; results use char positions
 *   - '.' matches any character (including newline)
 *   - class letters (%a %s %g ...) go through match_class(); an unknown
 *     letter such as %q is a literal (match_class's default)
 *   - '$' only anchors as the last pattern item; '^' is handled by the
 *     caller (the Lua glue strips it and passes an anchored flag instead)
 *   - %f[set] uses previous = 0 at the search start (luautf8's src_init
 *     semantics) and current = 0 at end of text
 *
 * Constructs this module deliberately does not implement make compilation
 * fail (nil is returned) so the caller falls back to the original Lua path:
 *   - capture backreferences %1..%9 and %b (balanced pair matching)
 *
 * Patterns that can match the empty string are also refused: the tokenizer
 * main loop skips such matches ("goto continue"), which cannot be expressed
 * with the priority cut used here without leaking those threads. Such
 * patterns are reported as bad by the original tokenizer anyway.
 */

/* Exported by src/api/utf8.c (vendored luautf8). */
extern const char *lite_utf8_decode(const char *s, const char *e, unsigned int *ch);
extern int lite_utf8_match_class(unsigned int ch, unsigned int cl);

#define TC_MAXSLOTS 64          /* Lua caps captures at 32 */
#define TC_NAME_PROG "tokenizer_c_prog"
#define TC_NAME_SET  "tokenizer_c_set"

/* ------------------------------------------------------------------ */
/* Data structures                                                     */

typedef struct {
  uint8_t is_cls;              /* 1: class letter via match_class; 0: range */
  uint8_t cl;                  /* class letter when is_cls */
  uint32_t lo, hi;             /* codepoint range when !is_cls */
} TCPred;

typedef struct {
  int negated;
  int n;
  TCPred *preds;
} TCClass;

enum {
  TC_CHAR,                     /* consume one char matching cls            */
  TC_ANY,                      /* consume any char                         */
  TC_SPLIT,                    /* try x first, then y (both inst indices)  */
  TC_JMP,                      /* jump to inst x                           */
  TC_SAVE,                     /* record current char pos into slot x      */
  TC_MATCH,                    /* report a match for the owning prog       */
  TC_FRONTIER,                 /* %f[cls]: prev not in cls and cur in cls  */
  TC_EOL                       /* '$': only passes at end of text          */
};

typedef struct {
  uint8_t op;
  uint32_t x, y;
  uint32_t cls;                /* index into the owning prog's class arena */
} TCInst;

typedef struct TCProg {
  TCInst *insts;
  uint32_t n;
  uint32_t nslots;             /* slots are 0..nslots-1 */
  uint32_t patid;              /* 1-based index in the syntax pattern list */
  uint8_t pos1_only;           /* pattern part started with '^' */
  uint8_t first[32];           /* first-byte bitmap (ASCII + multibyte leads) */
  uint8_t first_known;         /* 0: no first-byte restriction             */
  uint8_t can_empty;
  uint32_t base;               /* global inst offset inside the owning set */
  TCClass *classes;            /* owned class arena */
  uint32_t nclasses;
} TCProg;

typedef struct {
  uint32_t pc;
  TCProg *prog;
  uint32_t start_char, start_byte;
  int32_t slots[TC_MAXSLOTS];
} TCThread;

typedef struct {
  int matched;
  uint32_t patid;
  uint32_t s_char, e_char;
  uint32_t s_byte, eb_excl;
  uint32_t nslots;
  int32_t slots[TC_MAXSLOTS];
} TCMatch;

/* VM scratch: a set shares one for all its progs; a standalone prog has
   its own (base 0). */
typedef struct {
  TCThread *clist, *nlist;
  uint32_t cap;
  uint32_t *seen;              /* thread dedup, indexed by global inst */
  uint32_t gen;
  uint32_t total;
} TCScratch;

typedef struct {
  TCProg **progs;              /* compiled progs in pattern order */
  int n;
  TCScratch vm;
} TCSet;

/* ------------------------------------------------------------------ */
/* Character helpers                                                   */

static uint32_t tc_decode(const char *s, const char *e, int *len) {
  unsigned int ch = 0;
  const char *r = lite_utf8_decode(s, e, &ch);
  if (!r) { if (len) *len = 1; return 0xFFFD; }
  if (len) *len = (int)(r - s);
  return ch;
}

static int tc_class_test(const TCClass *c, uint32_t ch) {
  int in = 0;
  for (int i = 0; i < c->n; i++) {
    const TCPred *pr = &c->preds[i];
    if (pr->is_cls ? lite_utf8_match_class(ch, pr->cl)
                   : (ch >= pr->lo && ch <= pr->hi)) { in = 1; break; }
  }
  return c->negated ? !in : in;
}

static void tc_mask_add(uint8_t *mask, unsigned char b) {
  mask[b >> 3] |= (uint8_t)(1u << (b & 7));
}

static int tc_mask_test(const uint8_t *mask, unsigned char b) {
  return (mask[b >> 3] >> (b & 7)) & 1;
}

static void tc_mask_class(uint8_t *mask, const TCClass *c) {
  /* Exact for pure-ASCII ranges; classes and non-ASCII ranges get all
     multibyte lead bytes set (loose but correct). */
  int exact = 1;
  for (int i = 0; i < c->n; i++)
    if (c->preds[i].is_cls || c->preds[i].hi >= 0x80) { exact = 0; break; }
  if (exact && !c->negated) {
    for (int i = 0; i < c->n; i++)
      for (uint32_t ch = c->preds[i].lo; ch <= c->preds[i].hi && ch < 0x80; ch++)
        tc_mask_add(mask, (unsigned char)ch);
  } else {
    for (uint32_t ch = 0; ch < 0x80; ch++)
      if (tc_class_test(c, ch)) tc_mask_add(mask, (unsigned char)ch);
    for (int b = 0x80; b <= 0xFF; b++) tc_mask_add(mask, (unsigned char)b);
  }
}

/* ------------------------------------------------------------------ */
/* Compiler                                                            */

typedef struct {
  const char *src;             /* pattern bytes */
  size_t len;
  size_t pos;                  /* byte cursor */
  int error;
  int ncap;
  int next_slot;               /* 0-based slot ordinal */
  TCInst *insts;
  uint32_t n, cap;
  TCClass *classes;            /* arena for parsed classes */
  uint32_t nclasses, ccap;
} TCParser;

static TCInst *tc_emit(TCParser *ps, uint8_t op, uint32_t x, uint32_t y, uint32_t cls) {
  if (ps->n == ps->cap) {
    uint32_t ncap2 = ps->cap ? ps->cap * 2 : 32;
    TCInst *ni = realloc(ps->insts, (size_t)ncap2 * sizeof(TCInst));
    if (!ni) { ps->error = 1; return NULL; }
    ps->insts = ni; ps->cap = ncap2;
  }
  TCInst *in = &ps->insts[ps->n];
  in->op = op; in->x = x; in->y = y; in->cls = cls;
  ps->n++;
  return in;
}

/* Classes live in a growing arena; instructions reference them by index so
   that arena growth (realloc) never dangles pointers stored in insts. */
static int tc_newclass(TCParser *ps) {
  if (ps->nclasses == ps->ccap) {
    uint32_t ncap2 = ps->ccap ? ps->ccap * 2 : 8;
    TCClass *nc = realloc(ps->classes, (size_t)ncap2 * sizeof(TCClass));
    if (!nc) { ps->error = 1; return -1; }
    ps->classes = nc; ps->ccap = ncap2;
  }
  int ci = (int)ps->nclasses++;
  TCClass *c = &ps->classes[ci];
  c->negated = 0; c->n = 0; c->preds = NULL;
  return ci;
}

static void tc_class_add(TCParser *ps, int ci, uint8_t is_cls, uint8_t cl,
                         uint32_t lo, uint32_t hi) {
  TCClass *c = &ps->classes[ci];
  TCPred *np = realloc(c->preds, (size_t)(c->n + 1) * sizeof(TCPred));
  if (!np) { ps->error = 1; return; }
  c->preds = np;
  c->preds[c->n].is_cls = is_cls;
  c->preds[c->n].cl = cl;
  c->preds[c->n].lo = lo;
  c->preds[c->n].hi = hi;
  c->n++;
}

/* decode next pattern codepoint; len 0 at end; len may be NULL */
static uint32_t tc_pnext(TCParser *ps, int *len) {
  int dummy;
  if (!len) len = &dummy;
  if (ps->pos >= ps->len) { *len = 0; return 0; }
  uint32_t ch = tc_decode(ps->src + ps->pos, ps->src + ps->len, len);
  ps->pos += (size_t)*len;
  return ch;
}

static uint32_t tc_peek(TCParser *ps) {
  if (ps->pos >= ps->len) return 0;
  return tc_decode(ps->src + ps->pos, ps->src + ps->len, NULL);
}

/* Parse [...] (the leading '[' has been consumed). Returns the class
   arena index, or -1 on error. */
static int tc_parse_class(TCParser *ps) {
  int ci = tc_newclass(ps);
  if (ci < 0) return -1;
  if (ps->pos < ps->len && ps->src[ps->pos] == '^') {
    ps->classes[ci].negated = 1;
    ps->pos++;
  }
  int first = 1;
  uint32_t prev = 0; int have_prev = 0;
  while (ps->pos < ps->len) {
    if (ps->src[ps->pos] == ']' && !first) { ps->pos++; return ci; }
    first = 0;
    int len;
    uint32_t ch = tc_pnext(ps, &len);
    if (ch == '%' && ps->pos < ps->len) {
      uint8_t cl = (unsigned char)ps->src[ps->pos];
      ps->pos++;
      tc_class_add(ps, ci, 1, cl, 0, 0);
      prev = 0; have_prev = 0;
    } else if (ch == '-' && have_prev && ps->pos < ps->len && ps->src[ps->pos] != ']') {
      uint32_t hi = tc_pnext(ps, NULL);
      if (hi < prev) { ps->error = 1; return -1; }
      tc_class_add(ps, ci, 0, 0, prev, hi);
      prev = 0; have_prev = 0;
    } else {
      tc_class_add(ps, ci, 0, 0, ch, ch);
      prev = ch; have_prev = 1;
    }
    if (ps->error) return -1;
  }
  ps->error = 1;  /* unterminated class */
  return -1;
}

static int tc_compile_atom(TCParser *ps, int depth);

/* Compile items until ')' (depth > 0) or end of pattern (depth == 0). */
static int tc_compile_items(TCParser *ps, int depth) {
  while (ps->pos < ps->len) {
    if (ps->src[ps->pos] == ')') {
      if (depth <= 0) { ps->error = 1; return 0; }
      return 1;  /* caller consumes ')' */
    }
    if (!tc_compile_atom(ps, depth)) return 0;
  }
  if (depth > 0) { ps->error = 1; return 0; }  /* unclosed capture */
  return 1;
}

/*
 * Compile one atom with its optional quantifier.
 *
 * Quantifiers are visible only after the atom has been emitted, so every
 * atom is emitted behind a placeholder JMP at index sp which is then
 * patched:
 *   no quant : JMP body            (one extra hop, kept for simplicity)
 *   'x*'     : SPLIT body, exit ; body ; JMP sp
 *   'x+'     : JMP body ; body ; SPLIT body, after
 *   'x-'     : SPLIT exit, body ; body ; JMP sp     (lazy)
 *   'x?'     : SPLIT body, exit ; body
 */
static int tc_compile_atom(TCParser *ps, int depth) {
  int len;
  uint32_t ch = tc_pnext(ps, &len);
  uint32_t sp = ps->n;
  if (!tc_emit(ps, TC_JMP, sp + 1, 0, 0)) return 0;
  uint32_t body = ps->n;

  switch (ch) {
    case '(': {
      if (ps->ncap >= 32) { ps->error = 1; return 0; }
      int base = ps->next_slot;
      if (ps->pos < ps->len && ps->src[ps->pos] == ')') {
        /* position capture () */
        ps->pos++;
        ps->ncap++;
        ps->next_slot++;
        if (ps->next_slot > TC_MAXSLOTS) { ps->error = 1; return 0; }
        if (!tc_emit(ps, TC_SAVE, (uint32_t)base, 0, 0)) return 0;
        break;
      }
      ps->ncap++;
      ps->next_slot += 2;
      if (ps->next_slot > TC_MAXSLOTS) { ps->error = 1; return 0; }
      if (!tc_emit(ps, TC_SAVE, (uint32_t)base, 0, 0)) return 0;
      if (!tc_compile_items(ps, depth + 1)) return 0;
      if (ps->pos >= ps->len || ps->src[ps->pos] != ')') { ps->error = 1; return 0; }
      ps->pos++;
      if (!tc_emit(ps, TC_SAVE, (uint32_t)(base + 1), 0, 0)) return 0;
      break;
    }
    case '[': {
      int ci = tc_parse_class(ps);
      if (ci < 0) return 0;
      if (!tc_emit(ps, TC_CHAR, 0, 0, (uint32_t)ci)) return 0;
      break;
    }
    case '.':
      if (!tc_emit(ps, TC_ANY, 0, 0, 0)) return 0;
      break;
    case '%': {
      if (ps->pos >= ps->len) { ps->error = 1; return 0; }
      uint8_t cl = (unsigned char)ps->src[ps->pos];
      if ((cl >= '0' && cl <= '9') || cl == 'b') { ps->error = 1; return 0; }
      if (cl == 'f') {
        ps->pos++;
        if (ps->pos >= ps->len || ps->src[ps->pos] != '[') { ps->error = 1; return 0; }
        ps->pos++;
        int ci = tc_parse_class(ps);
        if (ci < 0) return 0;
        if (!tc_emit(ps, TC_FRONTIER, 0, 0, (uint32_t)ci)) return 0;
      } else {
        ps->pos++;
        int ci = tc_newclass(ps);
        if (ci < 0) return 0;
        tc_class_add(ps, ci, 1, cl, 0, 0);
        if (ps->error) return 0;
        if (!tc_emit(ps, TC_CHAR, 0, 0, (uint32_t)ci)) return 0;
      }
      break;
    }
    case '$': {
      if (ps->pos >= ps->len) {
        if (!tc_emit(ps, TC_EOL, 0, 0, 0)) return 0;
      } else {
        int ci = tc_newclass(ps);
        if (ci < 0) return 0;
        tc_class_add(ps, ci, 0, 0, '$', '$');
        if (ps->error) return 0;
        if (!tc_emit(ps, TC_CHAR, 0, 0, (uint32_t)ci)) return 0;
      }
      break;
    }
    default: {
      int ci = tc_newclass(ps);
      if (ci < 0) return 0;
      tc_class_add(ps, ci, 0, 0, ch, ch);
      if (ps->error) return 0;
      if (!tc_emit(ps, TC_CHAR, 0, 0, (uint32_t)ci)) return 0;
      break;
    }
  }
  if (ps->error) return 0;

  uint32_t body_end = ps->n;
  if (ps->pos < ps->len) {
    uint8_t q = (unsigned char)ps->src[ps->pos];
    if (q == '*' || q == '+' || q == '-' || q == '?') {
      ps->pos++;
      switch (q) {
        case '*':
          if (!tc_emit(ps, TC_JMP, sp, 0, 0)) return 0;
          ps->insts[sp].op = TC_SPLIT;
          ps->insts[sp].x = body;
          ps->insts[sp].y = ps->n;
          break;
        case '+':
          if (!tc_emit(ps, TC_SPLIT, body, ps->n + 1, 0)) return 0;
          break;
        case '-':
          if (!tc_emit(ps, TC_JMP, sp, 0, 0)) return 0;
          ps->insts[sp].op = TC_SPLIT;
          ps->insts[sp].x = ps->n;
          ps->insts[sp].y = body;
          break;
        case '?':
          ps->insts[sp].op = TC_SPLIT;
          ps->insts[sp].x = body;
          ps->insts[sp].y = body_end;
          break;
      }
    }
  }
  return 1;
}

/* Analyze first-byte mask and emptiness (epsilon reachability from inst 0). */
static void tc_analyze(TCProg *p) {
  uint32_t *stack = malloc((size_t)p->n * sizeof(uint32_t));
  uint8_t *vis = calloc((size_t)p->n, 1);
  if (!stack || !vis) { p->can_empty = 1; free(stack); free(vis); return; }
  uint32_t top = 0;
  stack[top++] = 0;
  vis[0] = 1;
  p->can_empty = 0;
  p->first_known = 0;
  while (top > 0) {
    uint32_t pc = stack[--top];
    TCInst *in = &p->insts[pc];
    switch (in->op) {
      case TC_JMP:
        if (!vis[in->x]) { vis[in->x] = 1; stack[top++] = in->x; }
        break;
      case TC_SPLIT:
        if (!vis[in->x]) { vis[in->x] = 1; stack[top++] = in->x; }
        if (!vis[in->y]) { vis[in->y] = 1; stack[top++] = in->y; }
        break;
      case TC_SAVE:
      case TC_FRONTIER:
      case TC_EOL:
        if (pc + 1 < p->n && !vis[pc + 1]) { vis[pc + 1] = 1; stack[top++] = pc + 1; }
        break;
      case TC_MATCH:
        p->can_empty = 1;
        break;
      case TC_CHAR:
        if (!p->first_known) { memset(p->first, 0, 32); p->first_known = 1; }
        tc_mask_class(p->first, &p->classes[in->cls]);
        break;
      case TC_ANY:
        p->first_known = 0;
        memset(p->first, 0xFF, 32);
        break;
    }
  }
  free(stack);
  free(vis);
}

static void tc_free_prog(TCProg *p) {
  if (!p) return;
  free(p->insts);
  if (p->classes)
    for (uint32_t i = 0; i < p->nclasses; i++) free(p->classes[i].preds);
  free(p->classes);
  free(p);
}

static TCProg *tc_compile(const char *src, size_t len) {
  if (len == 0) return NULL;
  /* reject NUL bytes: patterns are NUL-free */
  if (memchr(src, 0, len)) return NULL;

  TCParser ps;
  memset(&ps, 0, sizeof(ps));
  ps.src = src; ps.len = len;

  if (!tc_compile_items(&ps, 0) || ps.error || ps.pos != ps.len)
    goto fail;
  if (!tc_emit(&ps, TC_MATCH, 0, 0, 0) || ps.error)
    goto fail;

  {
    TCProg *p = calloc(1, sizeof(TCProg));
    if (!p) goto fail;
    p->insts = ps.insts;
    p->n = ps.n;
    p->nslots = (uint32_t)ps.next_slot;
    p->classes = ps.classes;
    p->nclasses = ps.nclasses;
    tc_analyze(p);
    if (p->can_empty) { tc_free_prog(p); return NULL; }
    return p;
  }

fail:
  free(ps.insts);
  if (ps.classes) {
    for (uint32_t i = 0; i < ps.nclasses; i++) free(ps.classes[i].preds);
    free(ps.classes);
  }
  return NULL;
}

/* ------------------------------------------------------------------ */
/* Pike VM                                                             */

/*
 * Add a thread at (prog, pc) to list, following epsilon instructions.
 * t carries the thread's captures and start position; its pc is ignored.
 * cur_* describe the position the list is being built for: the next
 * character to be consumed (SAVE records cur_char, FRONTIER compares
 * prev_cp with cur_cp where 0 means "before start" / "past end").
 */
static void tc_add(TCScratch *vm, TCThread *list, uint32_t *n,
                   TCProg *p, uint32_t pc, TCThread t,
                   uint32_t cur_char, uint32_t cur_byte,
                   uint32_t prev_cp, uint32_t cur_cp, int cur_valid,
                   uint32_t textlen, uint32_t gen) {
  for (;;) {
    uint32_t gi = p->base + pc;
    if (gi >= vm->total) return;           /* safety */
    if (vm->seen[gi] == gen) return;       /* already have this pc */
    vm->seen[gi] = gen;
    TCInst *in = &p->insts[pc];
    switch (in->op) {
      case TC_JMP:
        pc = in->x;
        continue;
      case TC_SPLIT: {
        TCThread t2 = t;
        t2.pc = in->x;
        tc_add(vm, list, n, p, in->x, t2, cur_char, cur_byte, prev_cp, cur_cp,
               cur_valid, textlen, gen);
        pc = in->y;
        continue;
      }
      case TC_SAVE:
        t.slots[in->x] = (int32_t)cur_char;
        pc = pc + 1;
        continue;
      case TC_FRONTIER: {
        uint32_t curc = cur_valid ? cur_cp : 0;
        if (!tc_class_test(&p->classes[in->cls], prev_cp) && tc_class_test(&p->classes[in->cls], curc)) {
          pc = pc + 1;
          continue;
        }
        return;
      }
      case TC_EOL:
        if (cur_byte == textlen) { pc = pc + 1; continue; }
        return;
      default:
        if (*n >= vm->cap) return;         /* safety */
        t.pc = pc;
        list[(*n)++] = t;
        return;
    }
  }
}

static void tc_fill_match(TCMatch *m, TCThread *t, uint32_t cur_char, uint32_t cur_byte) {
  m->matched = 1;
  m->patid = t->prog->patid;
  m->s_char = t->start_char;
  m->e_char = cur_char - 1;
  m->s_byte = t->start_byte;
  m->eb_excl = cur_byte;
  m->nslots = t->prog->nslots;
  memcpy(m->slots, t->slots, sizeof(m->slots));
}

/*
 * Run the simulation.
 *
 * set mode  (single == NULL): seed every prog with patid >= from_idx
 *   (skipping pos1_only patterns unless at_pos1), no reseeding. Returns
 *   the best match by pattern order; on no match fills *charlen_out.
 * search mode (single != NULL): seed single at (byte_i, char_i); when
 *   not anchored, reseed at each advanced position until a candidate
 *   exists (leftmost-first: later starts lose to earlier ones).
 *
 * Priority rule on TC_MATCH at list index i: if no higher-priority thread
 * survived into nlist this round, the match wins immediately; otherwise it
 * is remembered as the candidate, all lower-priority threads are cut, and
 * the simulation continues with the survivors. When the lists drain, the
 * candidate is the answer. This reproduces Lua's backtracking order
 * (alternation and greedy/lazy preferences) for all patterns the compiler
 * accepts.
 */
/* decode the codepoint just before byte_i (for %f's previous when the
   match anchor is mid-text, like luautf8's s != src_init case) */
static uint32_t tc_prev_cp(const char *text, uint32_t byte_i) {
  if (byte_i == 0) return 0;
  uint32_t p = byte_i - 1;
  while (p > 0 && ((unsigned char)text[p] & 0xC0) == 0x80) p--;
  int len;
  return tc_decode(text + p, text + byte_i, &len);
}

static int tc_run(TCScratch *vm, TCSet *set, TCProg *single,
                  const char *text, uint32_t textlen,
                  uint32_t byte_i, uint32_t char_i, int at_pos1, int anchored,
                  uint32_t from_idx, TCMatch *m, uint32_t *charlen_out) {
  TCThread *clist = vm->clist, *nlist = vm->nlist;
  uint32_t cn = 0, nn;
  uint32_t gen;

  uint32_t cchar = char_i, cbyte = byte_i;
  uint32_t cur_cp = 0; int cur_len = 1; int cur_valid = 0;
  if (cbyte < textlen) cur_cp = tc_decode(text + cbyte, text + textlen, &cur_len);
  cur_valid = (cbyte < textlen);
  uint32_t prev_cp = tc_prev_cp(text, byte_i);  /* luautf8: s != src_init uses *(s-1) */

  TCMatch cand;
  memset(&cand, 0, sizeof(cand));
  int have_cand = 0;

  /* seed */
  gen = ++vm->gen;
  {
    TCThread seed;
    memset(&seed, 0, sizeof(seed));
    seed.start_char = cchar; seed.start_byte = cbyte;
    if (single) {
      if (cur_valid && (!single->first_known || tc_mask_test(single->first, (unsigned char)text[cbyte]))) {
        seed.prog = single;
        tc_add(vm, clist, &cn, single, 0, seed, cchar, cbyte, prev_cp, cur_cp,
               cur_valid, textlen, gen);
      }
    } else {
      for (int i = 0; i < set->n; i++) {
        TCProg *p = set->progs[i];
        if (p->patid < from_idx) continue;
        if (p->pos1_only && !at_pos1) continue;
        if (cur_valid && p->first_known && !tc_mask_test(p->first, (unsigned char)text[cbyte]))
          continue;
        seed.prog = p;
        tc_add(vm, clist, &cn, p, 0, seed, cchar, cbyte, prev_cp, cur_cp,
               cur_valid, textlen, gen);
      }
    }
  }

  while (cn > 0 || (single && !anchored && !have_cand && cbyte < textlen)) {
    if (cn > 0) {
      nn = 0;
      gen = ++vm->gen;
      /* next position's character: FRONTIER in added threads must compare
         against the character after the one being consumed this round */
      uint32_t ncur_cp = 0;
      int ncur_valid = 0;
      if (cbyte + (uint32_t)cur_len < textlen) {
        ncur_cp = tc_decode(text + cbyte + (uint32_t)cur_len, text + textlen, NULL);
        ncur_valid = 1;
      }
      int cut = 0;
      for (uint32_t i = 0; i < cn; i++) {
        TCThread *t = &clist[i];
        TCInst *in = &t->prog->insts[t->pc];
        switch (in->op) {
          case TC_CHAR:
            if (cur_valid && tc_class_test(&t->prog->classes[in->cls], cur_cp)) {
              TCThread t2 = *t;
              t2.pc = t->pc + 1;
              tc_add(vm, nlist, &nn, t->prog, t->pc + 1, t2, cchar + 1,
                     cbyte + (uint32_t)cur_len, cur_cp, ncur_cp, ncur_valid, textlen, gen);
            }
            break;
          case TC_ANY:
            if (cur_valid) {
              TCThread t2 = *t;
              t2.pc = t->pc + 1;
              tc_add(vm, nlist, &nn, t->prog, t->pc + 1, t2, cchar + 1,
                     cbyte + (uint32_t)cur_len, cur_cp, ncur_cp, ncur_valid, textlen, gen);
            }
            break;
          case TC_MATCH: {
            if (cchar - 1 < t->start_char) break;  /* empty: refused at compile */
            if (nn == 0) {                         /* no higher-priority survivor */
              tc_fill_match(m, t, cchar, cbyte);
              return 1;
            }
            tc_fill_match(&cand, t, cchar, cbyte);
            have_cand = 1;
            cut = 1;
            break;                                  /* cut lower-priority threads */
          }
          default:
            break;                                  /* unreachable: closure done */
        }
        if (cut) break;
      }

      /* swap lists */
      { TCThread *tmp = clist; clist = nlist; nlist = tmp; }
      cn = nn;
    }

    /* advance one char */
    prev_cp = cur_cp;
    cbyte += (uint32_t)cur_len;
    cchar++;
    cur_cp = 0; cur_len = 1;
    if (cbyte < textlen) {
      cur_cp = tc_decode(text + cbyte, text + textlen, &cur_len);
      cur_valid = 1;
    } else {
      cur_valid = 0;
    }

    /* search mode: reseed at the new position until a candidate exists */
    if (single && !anchored && !have_cand && cbyte <= textlen) {
      int ok = 0;
      if (cbyte == textlen) {
        ok = 1;  /* let epsilon/MATCH paths run past the last char */
      } else if (!single->first_known || tc_mask_test(single->first, (unsigned char)text[cbyte])) {
        ok = 1;
      }
      if (ok) {
        TCThread seed;
        memset(&seed, 0, sizeof(seed));
        seed.start_char = cchar; seed.start_byte = cbyte;
        seed.prog = single;
        tc_add(vm, clist, &cn, single, 0, seed, cchar, cbyte, prev_cp, cur_cp,
               cur_valid, textlen, gen);
      }
    }
  }

  if (have_cand) {
    *m = cand;
    return 1;
  }
  if (charlen_out) {
    int l = 1;
    if (byte_i < textlen) tc_decode(text + byte_i, text + textlen, &l);
    *charlen_out = (uint32_t)l;
  }
  return 0;
}

/* Standalone progs (for close-delimiter searches) are boxed with their own
   VM scratch; sets share one scratch across all their progs. */
typedef struct {
  TCProg *p;
  TCScratch vm;
} TCProgBox;

/* ------------------------------------------------------------------ */
/* Lua API                                                             */

static TCProgBox *l_checkprog(lua_State *L, int idx) {
  TCProgBox **b = luaL_testudata(L, idx, TC_NAME_PROG);
  luaL_argcheck(L, b != NULL, idx, "tokenizer_c prog expected");
  return *b;
}

static TCSet *l_checkset(lua_State *L, int idx) {
  TCSet **s = luaL_testudata(L, idx, TC_NAME_SET);
  luaL_argcheck(L, s != NULL, idx, "tokenizer_c set expected");
  return *s;
}

/* push match results: s_char, e_char, s_byte, eb_excl, caps... */
static int l_push_match(lua_State *L, const TCMatch *m) {
  lua_pushinteger(L, (lua_Integer)m->s_char);
  lua_pushinteger(L, (lua_Integer)m->e_char);
  lua_pushinteger(L, (lua_Integer)m->s_byte);
  lua_pushinteger(L, (lua_Integer)m->eb_excl);
  for (uint32_t i = 0; i < m->nslots; i++) {
    if (m->slots[i] > 0) lua_pushinteger(L, (lua_Integer)m->slots[i]);
    else lua_pushnil(L);   /* unset capture, like Lua's find */
  }
  return (int)(4 + m->nslots);
}

static int tc_scratch_init(TCScratch *vm, uint32_t total) {
  memset(vm, 0, sizeof(*vm));
  vm->total = total ? total : 1;
  vm->cap = vm->total;
  vm->seen = calloc(vm->total, sizeof(uint32_t));
  vm->clist = calloc(vm->cap, sizeof(TCThread));
  vm->nlist = calloc(vm->cap, sizeof(TCThread));
  if (!vm->seen || !vm->clist || !vm->nlist) {
    free(vm->seen); free(vm->clist); free(vm->nlist);
    memset(vm, 0, sizeof(*vm));
    return 0;
  }
  return 1;
}

static void tc_scratch_free(TCScratch *vm) {
  free(vm->seen); free(vm->clist); free(vm->nlist);
  memset(vm, 0, sizeof(*vm));
}

/* compile(pattern) -> prog | nil */
static int l_compile(lua_State *L) {
  size_t len;
  const char *src = luaL_checklstring(L, 1, &len);
  TCProg *p = tc_compile(src, len);
  if (!p) { lua_pushnil(L); return 1; }
  TCProgBox *box = calloc(1, sizeof(TCProgBox));
  if (!box || !tc_scratch_init(&box->vm, p->n)) {
    if (box) free(box);
    tc_free_prog(p); lua_pushnil(L); return 1;
  }
  box->p = p;
  TCProgBox **ud = lua_newuserdata(L, sizeof(TCProgBox *));
  *ud = box;
  luaL_setmetatable(L, TC_NAME_PROG);
  return 1;
}

/* compile_set(opens, pos1) -> set | nil, supported */
static int l_compile_set(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  luaL_checktype(L, 2, LUA_TTABLE);
  lua_Integer n = luaL_len(L, 1);

  TCSet *set = calloc(1, sizeof(TCSet));
  if (!set) { lua_pushnil(L); lua_newtable(L); return 2; }
  set->progs = calloc((size_t)(n > 0 ? n : 1), sizeof(TCProg *));
  if (!set->progs) { free(set); lua_pushnil(L); lua_newtable(L); return 2; }

  uint32_t total = 0;
  for (lua_Integer i = 1; i <= n; i++) {
    lua_rawgeti(L, 1, i);
    size_t len;
    const char *src = lua_tolstring(L, -1, &len);
    if (src) {
      TCProg *p = tc_compile(src, len);
      if (p) {
        p->patid = (uint32_t)i;
        lua_rawgeti(L, 2, i);
        p->pos1_only = lua_toboolean(L, -1) ? 1 : 0;
        lua_pop(L, 1);
        p->base = total;
        total += p->n;
        set->progs[set->n++] = p;
      }
    }
    lua_pop(L, 1);
  }

  if (set->n == 0 || !tc_scratch_init(&set->vm, total)) {
    for (int i = 0; i < set->n; i++) tc_free_prog(set->progs[i]);
    free(set->progs);
    free(set);
    lua_pushnil(L);
    lua_newtable(L);
    return 2;
  }

  TCSet **ud = lua_newuserdata(L, sizeof(TCSet *));
  *ud = set;
  luaL_setmetatable(L, TC_NAME_SET);

  lua_newtable(L);  /* supported, aligned to pattern indices */
  int si = 0;
  for (lua_Integer i = 1; i <= n; i++) {
    int sup = 0;
    if (si < set->n && set->progs[si]->patid == (uint32_t)i) { sup = 1; si++; }
    lua_pushboolean(L, sup);
    lua_rawseti(L, -2, i);
  }
  return 2;
}

/* match_set(set, text, byte_i, char_i, at_pos1, [from_idx])
   -> patid, s_char, e_char, s_byte, eb_excl, caps... | nil, charlen */
static int l_match_set(lua_State *L) {
  TCSet *set = l_checkset(L, 1);
  size_t tlen;
  const char *text = luaL_checklstring(L, 2, &tlen);
  uint32_t byte_i = (uint32_t)luaL_checkinteger(L, 3);
  uint32_t char_i = (uint32_t)luaL_checkinteger(L, 4);
  int at_pos1 = lua_toboolean(L, 5);
  uint32_t from_idx = (uint32_t)luaL_optinteger(L, 6, 1);
  if (byte_i < 1 || byte_i > tlen + 1 || char_i < 1) {
    lua_pushnil(L); lua_pushinteger(L, 1); return 2;
  }
  byte_i--;  /* C is 0-based */
  TCMatch m;
  uint32_t charlen = 1;
  int rc = tc_run(&set->vm, set, NULL, text, (uint32_t)tlen, byte_i, char_i,
                  at_pos1, 1, from_idx, &m, &charlen);
  if (rc) {
    lua_pushinteger(L, (lua_Integer)m.patid);
    return 1 + l_push_match(L, &m);
  }
  lua_pushnil(L);
  lua_pushinteger(L, (lua_Integer)charlen);
  return 2;
}

/* search(prog, text, byte_i, char_i, anchored)
   -> s_char, e_char, s_byte, eb_excl, caps... | nil */
static int l_search(lua_State *L) {
  TCProgBox *b = l_checkprog(L, 1);
  size_t tlen;
  const char *text = luaL_checklstring(L, 2, &tlen);
  uint32_t byte_i = (uint32_t)luaL_checkinteger(L, 3);
  uint32_t char_i = (uint32_t)luaL_checkinteger(L, 4);
  int anchored = lua_toboolean(L, 5);
  if (byte_i < 1 || byte_i > tlen + 1 || char_i < 1) {
    lua_pushnil(L); return 1;
  }
  byte_i--;
  TCMatch m;
  if (tc_run(&b->vm, NULL, b->p, text, (uint32_t)tlen, byte_i, char_i,
             0, anchored, 1, &m, NULL)) {
    return l_push_match(L, &m);
  }
  lua_pushnil(L);
  return 1;
}

static int l_gc_prog(lua_State *L) {
  TCProgBox *b = *(TCProgBox **)luaL_checkudata(L, 1, TC_NAME_PROG);
  tc_scratch_free(&b->vm);
  tc_free_prog(b->p);
  free(b);
  return 0;
}

static int l_gc_set(lua_State *L) {
  TCSet *set = *(TCSet **)luaL_checkudata(L, 1, TC_NAME_SET);
  for (int i = 0; i < set->n; i++) tc_free_prog(set->progs[i]);
  free(set->progs);
  tc_scratch_free(&set->vm);
  free(set);
  return 0;
}

static const luaL_Reg tc_prog_meta[] = {
  { "__gc", l_gc_prog }, { NULL, NULL }
};

static const luaL_Reg tc_set_meta[] = {
  { "__gc", l_gc_set }, { NULL, NULL }
};

static const luaL_Reg tc_lib[] = {
  { "compile", l_compile },
  { "compile_set", l_compile_set },
  { "match_set", l_match_set },
  { "search", l_search },
  { NULL, NULL }
};

int luaopen_tokenizer_c(lua_State *L) {
  luaL_newlib(L, tc_lib);

  luaL_newmetatable(L, TC_NAME_PROG);
  luaL_setfuncs(L, tc_prog_meta, 0);
  lua_pop(L, 1);

  luaL_newmetatable(L, TC_NAME_SET);
  luaL_setfuncs(L, tc_set_meta, 0);
  lua_pop(L, 1);

  return 1;
}
