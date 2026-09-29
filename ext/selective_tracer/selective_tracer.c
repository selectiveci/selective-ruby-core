// selective_tracer — records which source files a single test executes.
//
// A test map is built from one question asked of every test: "which files
// did you run?". This extension answers it with two raw VM event hooks that
// never call back into Ruby while the test runs:
//
//   * RUBY_EVENT_LINE | CALL | B_CALL, registered globally so work done on
//     *any* thread is
//     attributed to the running test. Capybara drives a Puma server thread;
//     a hook scoped to the test's own thread (what rotoscope does) would map
//     every system test to nothing and let selection skip them wrongly.
//     Selective runs one test at a time per process, so "everything that ran
//     between start and stop" is the right attribution. Stray background
//     threads can only add files, which makes selection more conservative,
//     never less. CALL and B_CALL are not redundant with LINE: an endless
//     method (`def total = price * qty`) and a one-line block executed from
//     another file emit no line event of their own, so a line-only hook never
//     ties a test to the file they live in.
//
//   * RUBY_INTERNAL_EVENT_NEWOBJ (optional), which records the class of every
//     plain object allocated. A class whose file only ran at boot — an
//     ActiveRecord model with no methods of its own — executes no lines
//     during a test, so line events alone would never tie the test to it.
//     The classes are resolved to source files in Ruby after the test stops.
//
// Why not Ruby's Coverage module: it is process-global, so it cannot run next
// to SimpleCov, and while it is enabled Bootsnap cannot use its compile cache.
// Why not TracePoint from Ruby: every event re-enters the interpreter. The
// design follows what Datadog learned building datadog-ci-rb (line hook with
// pointer caching, allocation tracking for code-less classes), written for
// Selective's needs: several project roots, several ignored prefixes, and no
// Ruby API use inside the allocation hook.

#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/st.h>

#include <stdbool.h>
#include <string.h>

#define PATH_CACHE_SIZE 1024   // power of two
#define KLASS_CACHE_SIZE 4096  // power of two
#define MAX_PREFIXES 32
#define EXEC_EVENTS (RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_B_CALL)

struct prefix_list {
  int count;
  char *values[MAX_PREFIXES];
  long lengths[MAX_PREFIXES];
};

struct tracer {
  // { path(String) => true } for the test being recorded.
  VALUE files;

  // Absolute paths are kept only under one of `roots` and outside every
  // `ignored` prefix (bundled gems, Selective's own gems, tmp dirs).
  struct prefix_list roots;
  struct prefix_list ignored;

  // Consecutive line events almost always come from the same file, and the
  // path pointer of an iseq is stable, so a pointer comparison settles most
  // events. The strings are marked so a freed path's address can't be reused
  // for a different file and wrongly treated as "already seen".
  VALUE last_path;
  VALUE path_cache[PATH_CACHE_SIZE];

  bool allocations;
  bool running;

  // Classes allocated during the test. Keys are class VALUEs, pinned by mark.
  st_table *klasses;
  VALUE last_klass;
  VALUE klass_cache[KLASS_CACHE_SIZE];
};

static int mark_klass_i(st_data_t key, st_data_t _value, st_data_t _arg) {
  rb_gc_mark((VALUE)key);
  return ST_CONTINUE;
}

static void tracer_mark(void *ptr) {
  struct tracer *t = ptr;
  rb_gc_mark(t->files);
  rb_gc_mark(t->last_path);
  for (int i = 0; i < PATH_CACHE_SIZE; i++) rb_gc_mark(t->path_cache[i]);
  rb_gc_mark(t->last_klass);
  for (int i = 0; i < KLASS_CACHE_SIZE; i++) rb_gc_mark(t->klass_cache[i]);
  if (t->klasses) st_foreach(t->klasses, mark_klass_i, 0);
}

static void free_prefixes(struct prefix_list *list) {
  for (int i = 0; i < list->count; i++) xfree(list->values[i]);
  list->count = 0;
}

static void tracer_free(void *ptr) {
  struct tracer *t = ptr;
  // No hook cleanup needed: the VM marks every registered hook's data, so a
  // tracer that is still running is reachable and can't be freed.
  free_prefixes(&t->roots);
  free_prefixes(&t->ignored);
  if (t->klasses) st_free_table(t->klasses);
  xfree(t);
}

static size_t tracer_memsize(const void *ptr) {
  return sizeof(struct tracer);
}

static const rb_data_type_t tracer_type = {
    .wrap_struct_name = "selective_tracer",
    .function = {.dmark = tracer_mark, .dfree = tracer_free, .dsize = tracer_memsize},
    .flags = RUBY_TYPED_FREE_IMMEDIATELY};

static void reset_caches(struct tracer *t) {
  t->last_path = Qnil;
  for (int i = 0; i < PATH_CACHE_SIZE; i++) t->path_cache[i] = Qnil;
  t->last_klass = Qnil;
  for (int i = 0; i < KLASS_CACHE_SIZE; i++) t->klass_cache[i] = Qnil;
}

static VALUE tracer_alloc(VALUE klass) {
  struct tracer *t;
  VALUE self = TypedData_Make_Struct(klass, struct tracer, &tracer_type, t);
  t->files = Qnil;
  t->roots.count = 0;
  t->ignored.count = 0;
  t->allocations = false;
  t->running = false;
  t->klasses = NULL;
  reset_caches(t);
  t->files = rb_hash_new();
  t->klasses = st_init_numtable();
  return self;
}

static struct tracer *get_tracer(VALUE self) {
  struct tracer *t;
  TypedData_Get_Struct(self, struct tracer, &tracer_type, t);
  return t;
}

static bool has_dir_prefix(const char *path, long path_len, const char *prefix, long prefix_len) {
  if (prefix_len > path_len || memcmp(prefix, path, prefix_len) != 0) return false;
  // "/app" must not match "/application"; a prefix given with a trailing
  // slash already carries the boundary.
  return prefix_len == path_len || prefix[prefix_len - 1] == '/' || path[prefix_len] == '/';
}

static bool path_included(struct tracer *t, const char *path, long len) {
  if (len == 0) return false;

  if (path[0] != '/') {
    // Relative paths ("./spec/x_spec.rb" from `load`) are resolved and
    // re-checked in Ruby. Pseudo-paths like "(eval at ...)" and
    // "<internal:kernel>" are never project files.
    return path[0] != '(' && path[0] != '<';
  }

  bool in_root = false;
  for (int i = 0; i < t->roots.count; i++) {
    if (has_dir_prefix(path, len, t->roots.values[i], t->roots.lengths[i])) {
      in_root = true;
      break;
    }
  }
  if (!in_root) return false;

  for (int i = 0; i < t->ignored.count; i++) {
    if (has_dir_prefix(path, len, t->ignored.values[i], t->ignored.lengths[i])) return false;
  }
  return true;
}

static inline size_t cache_slot(uintptr_t ptr, size_t size) {
  return ((ptr >> 4) ^ (ptr >> 12)) & (size - 1);
}

static void on_exec(rb_event_flag_t event, VALUE data, VALUE self, ID id, VALUE klass) {
  struct tracer *t = RTYPEDDATA_DATA(data);

  const char *current = rb_sourcefile();
  if (current == NULL) return;

  if (t->last_path != Qnil && RSTRING_PTR(t->last_path) == current) return;

  size_t slot = cache_slot((uintptr_t)current, PATH_CACHE_SIZE);
  VALUE cached = t->path_cache[slot];
  if (cached != Qnil && RSTRING_PTR(cached) == current) {
    t->last_path = cached;
    return;
  }

  // First time this test sees this file: fetch the frame's path String so
  // the pointer we cache is owned by a marked object.
  VALUE frame;
  if (rb_profile_frames(0, 1, &frame, NULL) != 1) return;

  VALUE path = rb_profile_frame_path(frame);
  if (NIL_P(path) || !RB_TYPE_P(path, T_STRING)) return;

  t->last_path = path;
  t->path_cache[slot] = path;

  if (path_included(t, RSTRING_PTR(path), RSTRING_LEN(path))) {
    rb_hash_aset(t->files, path, Qtrue);
  }
}

// Runs inside object allocation: no Ruby method calls and no Ruby object
// allocation are allowed here. rb_obj_class, rb_mod_name and st_* do neither.
static void on_newobj(VALUE data, rb_trace_arg_t *targ) {
  VALUE obj = rb_tracearg_object(targ);
  enum ruby_value_type type = rb_type(obj);
  if (type != RUBY_T_OBJECT && type != RUBY_T_STRUCT) return;

  VALUE klass = rb_obj_class(obj);
  if (klass == 0 || NIL_P(klass)) return;

  struct tracer *t = RTYPEDDATA_DATA(data);
  if (t->last_klass == klass) return;

  size_t slot = cache_slot((uintptr_t)klass, KLASS_CACHE_SIZE);
  if (t->klass_cache[slot] == klass) {
    t->last_klass = klass;
    return;
  }

  t->last_klass = klass;
  t->klass_cache[slot] = klass;

  if (st_is_member(t->klasses, (st_data_t)klass)) return;
  if (NIL_P(rb_mod_name(klass))) return;  // anonymous class: no file to resolve

  st_insert(t->klasses, (st_data_t)klass, 1);
}

static void load_prefixes(struct prefix_list *list, VALUE ary, const char *name) {
  if (NIL_P(ary)) return;
  Check_Type(ary, T_ARRAY);
  long n = RARRAY_LEN(ary);
  if (n > MAX_PREFIXES) rb_raise(rb_eArgError, "at most %d %s are supported", MAX_PREFIXES, name);

  for (long i = 0; i < n; i++) {
    VALUE s = rb_ary_entry(ary, i);
    Check_Type(s, T_STRING);
    long len = RSTRING_LEN(s);
    if (len == 0) continue;
    char *copy = ALLOC_N(char, len + 1);
    memcpy(copy, RSTRING_PTR(s), len);
    copy[len] = '\0';
    list->values[list->count] = copy;
    list->lengths[list->count] = len;
    list->count++;
  }
}

// NativeTracer.new(roots: [...], ignored: [...], allocations: true/false)
static VALUE tracer_initialize(int argc, VALUE *argv, VALUE self) {
  VALUE opts;
  rb_scan_args(argc, argv, "1", &opts);
  Check_Type(opts, T_HASH);

  struct tracer *t = get_tracer(self);
  free_prefixes(&t->roots);
  free_prefixes(&t->ignored);

  load_prefixes(&t->roots, rb_hash_aref(opts, ID2SYM(rb_intern("roots"))), "roots");
  load_prefixes(&t->ignored, rb_hash_aref(opts, ID2SYM(rb_intern("ignored"))), "ignored prefixes");
  if (t->roots.count == 0) rb_raise(rb_eArgError, "roots must contain at least one path");

  t->allocations = RTEST(rb_hash_aref(opts, ID2SYM(rb_intern("allocations"))));
  return self;
}

static VALUE tracer_start(VALUE self) {
  struct tracer *t = get_tracer(self);
  if (t->running) rb_raise(rb_eRuntimeError, "tracer is already running");

  rb_hash_clear(t->files);
  st_clear(t->klasses);
  reset_caches(t);

  rb_add_event_hook2((rb_event_hook_func_t)on_exec, EXEC_EVENTS, self, RUBY_EVENT_HOOK_FLAG_SAFE);
  if (t->allocations) {
    rb_add_event_hook2((rb_event_hook_func_t)on_newobj, RUBY_INTERNAL_EVENT_NEWOBJ, self,
                       RUBY_EVENT_HOOK_FLAG_SAFE | RUBY_EVENT_HOOK_FLAG_RAW_ARG);
  }
  t->running = true;
  return self;
}

static int collect_klass_i(st_data_t key, st_data_t _value, st_data_t ary) {
  rb_ary_push((VALUE)ary, (VALUE)key);
  return ST_CONTINUE;
}

// Returns [files, classes]: the Hash of executed paths and the Array of named
// classes allocated during the test. Both are fresh objects owned by Ruby.
static VALUE tracer_stop(VALUE self) {
  struct tracer *t = get_tracer(self);
  if (!t->running) rb_raise(rb_eRuntimeError, "tracer is not running");

  rb_remove_event_hook_with_data((rb_event_hook_func_t)on_exec, self);
  if (t->allocations) rb_remove_event_hook_with_data((rb_event_hook_func_t)on_newobj, self);
  t->running = false;

  VALUE files = t->files;
  t->files = rb_hash_new();

  VALUE klasses = rb_ary_new_capa((long)t->klasses->num_entries);
  st_foreach(t->klasses, collect_klass_i, (st_data_t)klasses);
  st_clear(t->klasses);
  reset_caches(t);

  return rb_assoc_new(files, klasses);
}

static VALUE tracer_running_p(VALUE self) {
  return get_tracer(self)->running ? Qtrue : Qfalse;
}

void Init_selective_tracer(void) {
  VALUE mSelective = rb_define_module("Selective");
  VALUE mRuby = rb_define_module_under(mSelective, "Ruby");
  VALUE mCore = rb_define_module_under(mRuby, "Core");
  VALUE mTestMap = rb_define_module_under(mCore, "TestMap");
  VALUE cTracer = rb_define_class_under(mTestMap, "NativeTracer", rb_cObject);

  rb_define_alloc_func(cTracer, tracer_alloc);
  rb_define_method(cTracer, "initialize", tracer_initialize, -1);
  rb_define_method(cTracer, "start", tracer_start, 0);
  rb_define_method(cTracer, "stop", tracer_stop, 0);
  rb_define_method(cTracer, "running?", tracer_running_p, 0);
}
