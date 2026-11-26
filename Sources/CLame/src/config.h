#ifndef CLAME_CONFIG_H
#define CLAME_CONFIG_H

#define PACKAGE "lame"
#define VERSION "4.0"

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MATH_H 1
#define HAVE_MEMORY_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1

#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_UNSIGNED_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8

#define IEEE754_FLOAT32_T float
#define IEEE754_FLOAT64_T double
#define HAVE_IEEE754_FLOAT32_T 1
#define HAVE_IEEE754_FLOAT64_T 1
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
#define TAKEHIRO_IEEE754_HACK 1
#define USE_FAST_LOG 1

#if defined(__BIG_ENDIAN__)
#define WORDS_BIGENDIAN 1
#endif

#endif /* CLAME_CONFIG_H */
