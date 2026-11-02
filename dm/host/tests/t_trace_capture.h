// Capture only a fixture's stderr; temporary bytes disappear on fclose.
#pragma once
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
typedef struct { FILE *file; int saved; } TraceCapture;
static TraceCapture trace_capture_begin(void) {
    fflush(stderr); TraceCapture capture = {tmpfile(),dup(STDERR_FILENO)};
    assert(capture.file && capture.saved >= 0);
    assert(dup2(fileno(capture.file),STDERR_FILENO) >= 0); return capture;
}
static char *trace_capture_end(TraceCapture capture) {
    fflush(stderr); assert(dup2(capture.saved,STDERR_FILENO) >= 0); close(capture.saved);
    assert(!fseek(capture.file,0,SEEK_END)); long size = ftell(capture.file); assert(size >= 0);
    assert(!fseek(capture.file,0,SEEK_SET)); char *text = calloc((size_t)size + 1,1); assert(text);
    assert(fread(text,1,(size_t)size,capture.file) == (size_t)size); fclose(capture.file); return text;
}
