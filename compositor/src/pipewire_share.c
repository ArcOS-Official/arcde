/* PipeWire producer for arc's screen share (compositor/src/ShareStream.zig).
 *
 * One pw_stream publishing raw video. Unlike the shell-side portal producer
 * (shell/src/pipewire_capture.c), which copies a finished frame into
 * whatever PipeWire dequeues, this one calls back into the compositor and
 * lets it render straight into the PipeWire buffer.
 *
 * Why that matters: the portal version would add a full-frame memcpy on top
 * of the compositor's own rasterisation (render -> owned frame -> PipeWire
 * buffer). Rendering directly into the dequeued buffer keeps it to one pass.
 *
 * Single-threaded by contract: the compositor's main thread owns the loop
 * and calls pshare_dispatch() from a timer. No locks inside; pw_loop_enter()
 * is taken once at create and left at destroy.
 *
 * Memory is allocated by PipeWire (MemPtr, the default when no explicit
 * buffer type is negotiated) and handed to the render callback as a raw
 * pointer. The callback wraps it in a wlr.Buffer for the duration of the
 * call; it does not own it.
 */

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <drm_fourcc.h>
#include <stdlib.h>
#include <string.h>

/* Render callback. Return 1 if dst now holds a frame, 0 to send black.
 * `drm_format` is DRM_FORMAT_XRGB8888 and `stride` is bytes per row. */
typedef int (*pshare_render_fn)(void *user, void *dst, uint32_t stride,
	uint32_t width, uint32_t height, uint32_t drm_format);

struct pshare {
	struct pw_main_loop *loop;
	struct pw_stream *stream;
	struct spa_hook state_hook;
	struct spa_hook process_hook;
	uint32_t node_id;
	int connected;	/* stream reached at least PAUSED: a consumer is linked */
	int negotiated;	/* format accepted, buffers flow */

	int width;
	int height;
	uint32_t stride;
	uint32_t format;	/* SPA_VIDEO_FORMAT_* */
	uint32_t drm_format;	/* DRM_FORMAT_* the compositor renders */

	pshare_render_fn render;
	void *user;

	/* Sticky until the next good frame, so an occasional poll still
	 * notices a compositor that cannot produce images. */
	int last_render_failed;
};

static void
on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state next, const char *error)
{
	struct pshare *p = data;
	(void)old;
	/* PAUSED (or later) means the graph connected us to a consumer. */
	p->connected = next >= PW_STREAM_STATE_PAUSED;
	if (error)
		pw_log_warn("share stream error: %s", error);
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
};

static void on_process(void *data);

static const struct pw_stream_events process_events = {
	PW_VERSION_STREAM_EVENTS,
	.process = on_process,
};

static void
on_process(void *data)
{
	struct pshare *p = data;
	struct pw_buffer *buf;
	unsigned char *dst;
	uint32_t size;
	int ok;

	if ((buf = pw_stream_dequeue_buffer(p->stream)) == NULL)
		return;
	if (buf->buffer == NULL || buf->buffer->n_datas == 0 ||
	    buf->buffer->datas[0].data == NULL) {
		pw_stream_queue_buffer(p->stream, buf);
		return;
	}

	dst = buf->buffer->datas[0].data;
	size = p->stride * (uint32_t)p->height;
	if (buf->buffer->datas[0].maxsize < size) {
		/* PipeWire gave us less than we asked for. Send an empty frame
		 * rather than overrunning it. */
		buf->size = 0;
		buf->requested = 0;
		pw_stream_queue_buffer(p->stream, buf);
		return;
	}

	if (p->render != NULL)
		ok = p->render(p->user, dst, p->stride, (uint32_t)p->width,
		    (uint32_t)p->height, p->drm_format);
	else
		ok = 0;
	if (!ok) {
		/* Nothing composed yet (share just started, or the source
		 * vanished). Black is honest; stale memory is not. */
		memset(dst, 0, size);
		p->last_render_failed = 1;
	} else {
		p->last_render_failed = 0;
	}

	buf->size = size;
	buf->requested = size;
	pw_stream_queue_buffer(p->stream, buf);
}

/* Returns NULL on failure. `render` may be NULL, in which case every frame
 * is black -- useful for negotiating the graph before the scene exists. */
struct pshare *
pshare_create(const char *name, int width, int height, uint32_t stride,
    uint32_t drm_format, pshare_render_fn render, void *user)
{
	uint32_t spa_format;
	struct pshare *p;
	struct spa_pod_builder b;
	const struct spa_pod *params[2];
	struct pw_properties *props;
	uint8_t buffer[2048];
	uint32_t size;

	if (width <= 0 || height <= 0 || stride == 0)
		return NULL;
	/* The compositor renders XRGB8888; map it to the matching raw format
	 * here rather than making the caller keep two enums in step. */
	if (drm_format != DRM_FORMAT_XRGB8888)
		return NULL;
	spa_format = SPA_VIDEO_FORMAT_BGRx;
	if ((p = calloc(1, sizeof(*p))) == NULL)
		return NULL;
	p->width = width;
	p->height = height;
	p->stride = stride;
	p->format = spa_format;
	p->drm_format = drm_format;
	p->render = render;
	p->user = user;
	size = (uint32_t)stride * (uint32_t)height;

	p->loop = pw_main_loop_new(NULL);
	if (p->loop == NULL)
		goto err;

	props = pw_properties_new(NULL, NULL);
	if (props == NULL)
		goto err;
	pw_properties_set(props, PW_KEY_MEDIA_CLASS, "Video/Source");
	pw_properties_set(props, PW_KEY_MEDIA_ROLE, "Screen");
	pw_properties_set(props, PW_KEY_NODE_NAME, name);
	pw_properties_set(props, PW_KEY_NODE_DESCRIPTION, "arc screen share");

	p->stream = pw_stream_new_simple(pw_main_loop_get_loop(p->loop), name,
			props, NULL, NULL);
	if (p->stream == NULL)
		goto err;

	pw_stream_add_listener(p->stream, &p->state_hook, &stream_events, p);
	pw_stream_add_listener(p->stream, &p->process_hook, &process_events, p);

	spa_pod_builder_init(&b, buffer, sizeof(buffer));
	params[0] = spa_pod_builder_add_object(&b,
			SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
			SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
			SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
			SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_RANGE_Int(spa_format, spa_format, spa_format),
			SPA_FORMAT_VIDEO_framerate,
				SPA_POD_CHOICE_RANGE_Fraction(SPA_FRACTION(30, 1),
					SPA_FRACTION(0, 1), SPA_FRACTION(60, 1)),
			NULL);
	/* One frame per buffer at our exact stride: the default raw-video
	 * allocation only guarantees a couple of rows. CPU buffers only, so
	 * no BufferTensors param. */
	params[1] = spa_pod_builder_add_object(&b,
			SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
			SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(size, size, size),
			SPA_PARAM_BUFFERS_stride, SPA_POD_CHOICE_RANGE_Int(stride, stride, stride),
			NULL);

	/* AUTOCONNECT: attach a consumer as soon as one appears. MAP_BUFFERS:
	 * we fill dequeued buffers ourselves -- which is the whole point,
	 * the compositor renders straight into them. */
	if (pw_stream_connect(p->stream, PW_DIRECTION_OUTPUT, (uint32_t)PW_ID_ANY,
				PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
				params, 2) < 0)
		goto err;

	p->negotiated = 1;
	pw_loop_enter(pw_main_loop_get_loop(p->loop));
	p->node_id = pw_stream_get_node_id(p->stream);
	return p;

err:
	if (p->stream)
		pw_stream_destroy(p->stream);
	if (p->loop)
		pw_main_loop_destroy(p->loop);
	free(p);
	return NULL;
}

void
pshare_destroy(struct pshare *p)
{
	if (p == NULL)
		return;
	pw_loop_leave(pw_main_loop_get_loop(p->loop));
	pw_stream_destroy(p->stream);
	pw_main_loop_destroy(p->loop);
	free(p);
}

/* Event-loop fd, so the caller can poll rather than spin. -1 if none. */
int
pshare_fd(struct pshare *p)
{
	if (p == NULL)
		return -1;
	return pw_loop_get_fd(pw_main_loop_get_loop(p->loop));
}

void
pshare_dispatch(struct pshare *p)
{
	if (p == NULL)
		return;
	pw_loop_iterate(pw_main_loop_get_loop(p->loop), 0);
}

uint32_t
pshare_node_id(struct pshare *p)
{
	if (p == NULL)
		return 0;
	return p->node_id;
}

int
pshare_connected(struct pshare *p)
{
	return p != NULL && p->connected;
}

int
pshare_render_failed(struct pshare *p)
{
	return p != NULL && p->last_render_failed;
}