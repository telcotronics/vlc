/*****************************************************************************
 * macosx.m: MacOS X OpenGL provider
 *****************************************************************************
 * Copyright (C) 2001-2012 the VideoLAN team
 * $Id$
 *
 * Authors: Colin Delacroix <colin@zoy.org>
 *          Florian G. Pflug <fgp@phlo.org>
 *          Jon Lech Johansen <jon-vl@nanocrew.net>
 *          Derk-Jan Hartman <hartman at videolan dot org>
 *          Eric Petit <titer@m0k.org>
 *          Benjamin Pracht <bigben at videolan dot org>
 *          Damien Fouilleul <damienf at videolan dot org>
 *          Pierre d'Herbemont <pdherbemont at videolan dot org>
 *          Felix Paul Kühne <fkuehne at videolan dot org>
 *          David Fuhrmann <david dot fuhrmann at googlemail dot com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

/*****************************************************************************
 * Preamble
 *****************************************************************************/

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <dlfcn.h>

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_vout_display.h>
#include <vlc_opengl.h>
#include <vlc_dialog.h>
#include "opengl.h"

@interface NSWindow (VLCCustomCode)
- (BOOL)isFullscreen;
@end

/**
 * Forward declarations
 */
static int Open (vlc_object_t *);
static void Close (vlc_object_t *);

static picture_pool_t *Pool (vout_display_t *vd, unsigned requested_count);
static void PictureRender (vout_display_t *vd, picture_t *pic, subpicture_t *subpicture);
static void PictureDisplay (vout_display_t *vd, picture_t *pic, subpicture_t *subpicture);
static int Control (vout_display_t *vd, int query, va_list ap);

static void *OurGetProcAddress(vlc_gl_t *, const char *);

static int OpenglLock (vlc_gl_t *gl);
static void OpenglUnlock (vlc_gl_t *gl);
static void OpenglSwap (vlc_gl_t *gl);

/**
 * Module declaration
 */
vlc_module_begin ()
    /* Will be loaded even without interface module. see voutgl.m */
    set_shortname ("Mac OS X")
    set_description (N_("Mac OS X OpenGL video output (requires drawable-nsobject)"))
    set_category (CAT_VIDEO)
    set_subcategory (SUBCAT_VIDEO_VOUT )
    set_capability ("vout display", 300)
    set_callbacks (Open, Close)

    add_shortcut ("macosx", "vout_macosx")
vlc_module_end ()

/**
 * Obj-C protocol declaration that drawable-nsobject should follow
 */
@protocol VLCOpenGLVideoViewEmbedding <NSObject>
- (void)addVoutSubview:(NSView *)view;
- (void)removeVoutSubview:(NSView *)view;
@end

@interface VLCOpenGLVideoView : NSOpenGLView
{
    vout_display_t *vd;
    BOOL _hasPendingReshape;
}
- (void)setVoutDisplay:(vout_display_t *)vd;
- (vout_display_t *)voutDisplay;
- (void)setVoutFlushing:(BOOL)flushing;
@end


struct vout_display_sys_t
{
    VLCOpenGLVideoView *glView;
    id<VLCOpenGLVideoViewEmbedding> container;

    vout_window_t *embed;
    vlc_gl_t gl;
    vout_display_opengl_t *vgl;

    picture_pool_t *pool;
    picture_t *current;
    bool has_first_frame;
};


static void *OurGetProcAddress(vlc_gl_t *gl, const char *name)
{
    VLC_UNUSED(gl);

    return dlsym(RTLD_DEFAULT, name);
}

static int Open (vlc_object_t *this)
{
    vout_display_t *vd = (vout_display_t *)this;
    vout_display_sys_t *sys = calloc (1, sizeof(*sys));
    NSAutoreleasePool *nsPool = nil;

    if (!sys)
        return VLC_ENOMEM;

    if (!CGDisplayUsesOpenGLAcceleration (kCGDirectMainDisplay))
    {
        msg_Err (this, "no OpenGL hardware acceleration found. this can lead to slow output and unexpected results");
        dialog_Fatal (this, _("OpenGL acceleration is not supported on your Mac"), _("Your Mac lacks Quartz Extreme acceleration, which is required for video output. It will still work, but much slower and with possibly unexpected results."));
    }
    else
        msg_Dbg (this, "Quartz Extreme acceleration is active");

    vd->sys = sys;
    sys->pool = NULL;
    sys->gl.sys = NULL;
    sys->embed = NULL;

    /* Get the drawable object */
    id container = var_CreateGetAddress (vd, "drawable-nsobject");
    if (container)
    {
        vout_display_DeleteWindow (vd, NULL);
    }
    else
    {
        vout_window_cfg_t wnd_cfg;

        memset (&wnd_cfg, 0, sizeof (wnd_cfg));
        wnd_cfg.type = VOUT_WINDOW_TYPE_NSOBJECT;
        wnd_cfg.x = var_InheritInteger (vd, "video-x");
        wnd_cfg.y = var_InheritInteger (vd, "video-y");
        wnd_cfg.width  = vd->cfg->display.width;
        wnd_cfg.height = vd->cfg->display.height;

        sys->embed = vout_display_NewWindow (vd, &wnd_cfg);
        if (sys->embed)
            container = sys->embed->handle.nsobject;

        if (!container)
        {
            msg_Dbg(vd, "No drawable-nsobject nor vout_window_t found, passing over.");
            goto error;
        }
    }

    /* This will be released in Close(), on
     * main thread, after we are done using it. */
    sys->container = [container retain];

    /* Get our main view*/
    nsPool = [[NSAutoreleasePool alloc] init];

    [VLCOpenGLVideoView performSelectorOnMainThread:@selector(getNewView:) withObject:[NSValue valueWithPointer:&sys->glView] waitUntilDone:YES];
    if (!sys->glView)
        goto error;

    [sys->glView setVoutDisplay:vd];

    /* We don't wait, that means that we'll have to be careful about releasing
     * container.
     * That's why we'll release on main thread in Close(). */
    if ([(id)container respondsToSelector:@selector(addVoutSubview:)])
        [(id)container performSelectorOnMainThread:@selector(addVoutSubview:) withObject:sys->glView waitUntilDone:NO];
    else if ([container isKindOfClass:[NSView class]])
    {
        NSView *parentView = container;
        [parentView performSelectorOnMainThread:@selector(addSubview:) withObject:sys->glView waitUntilDone:NO];
        [sys->glView performSelectorOnMainThread:@selector(setFrameWithValue:) withObject:[NSValue valueWithRect:[parentView bounds]] waitUntilDone:NO];
    }
    else
    {
        msg_Err(vd, "Invalid drawable-nsobject object. drawable-nsobject must either be an NSView or comply to the @protocol VLCOpenGLVideoViewEmbedding.");
        goto error;
    }


    [nsPool release];
    nsPool = nil;

    /* Initialize common OpenGL video display */
    sys->gl.lock = OpenglLock;
    sys->gl.unlock = OpenglUnlock;
    sys->gl.swap = OpenglSwap;
    sys->gl.getProcAddress = OurGetProcAddress;
    sys->gl.sys = sys;
    const vlc_fourcc_t *subpicture_chromas;
    video_format_t fmt = vd->fmt;

    sys->vgl = vout_display_opengl_New (&vd->fmt, &subpicture_chromas, &sys->gl);
    if (!sys->vgl)
    {
        sys->gl.sys = NULL;
        goto error;
    }

    /* */
    vout_display_info_t info = vd->info;
    info.has_pictures_invalid = false;
    info.has_event_thread = true;
    info.subpicture_chromas = subpicture_chromas;

    /* Setup vout_display_t once everything is fine */
    vd->info = info;

    vd->pool = Pool;
    vd->prepare = PictureRender;
    vd->display = PictureDisplay;
    vd->control = Control;

    /* */
    vout_display_SendEventDisplaySize (vd, vd->source.i_visible_width, vd->source.i_visible_height, false);

    return VLC_SUCCESS;

error:
    [nsPool release];
    Close(this);
    return VLC_EGENERIC;
}

void Close (vlc_object_t *this)
{
    vout_display_t *vd = (vout_display_t *)this;
    vout_display_sys_t *sys = vd->sys;

    if ([[sys->glView window] level] != NSNormalWindowLevel)
        [[sys->glView window] setLevel: NSNormalWindowLevel];

    [sys->glView setVoutDisplay:nil];

    var_Destroy (vd, "drawable-nsobject");
    if ([(id)sys->container respondsToSelector:@selector(removeVoutSubview:)])
    {
        /* This will retain sys->glView */
        [(id)sys->container performSelectorOnMainThread:@selector(removeVoutSubview:) withObject:sys->glView waitUntilDone:NO];
    }
    /* release on main thread as explained in Open() */
    [(id)sys->container performSelectorOnMainThread:@selector(release) withObject:nil waitUntilDone:NO];
    [sys->glView performSelectorOnMainThread:@selector(removeFromSuperview) withObject:nil waitUntilDone:NO];

    [sys->glView release];

    if (sys->gl.sys != NULL)
        vout_display_opengl_Delete (sys->vgl);

    if (sys->embed)
        vout_display_DeleteWindow (vd, sys->embed);
    free (sys);
}

/*****************************************************************************
 * vout display callbacks
 *****************************************************************************/

static picture_pool_t *Pool (vout_display_t *vd, unsigned requested_count)
{
    vout_display_sys_t *sys = vd->sys;

    if (!sys->pool)
        sys->pool = vout_display_opengl_GetPool (sys->vgl, requested_count);
    assert(sys->pool);
    return sys->pool;
}

static void PictureRender (vout_display_t *vd, picture_t *pic, subpicture_t *subpicture)
{

    vout_display_sys_t *sys = vd->sys;

    vout_display_opengl_Prepare (sys->vgl, pic, subpicture);
}

static void PictureDisplay (vout_display_t *vd, picture_t *pic, subpicture_t *subpicture)
{
    vout_display_sys_t *sys = vd->sys;
    [sys->glView setVoutFlushing:YES];
    vout_display_opengl_Display (sys->vgl, &vd->source);
    [sys->glView setVoutFlushing:NO];
    picture_Release (pic);
    sys->has_first_frame = true;

    if (subpicture)
        subpicture_Delete(subpicture);
}

static int Control (vout_display_t *vd, int query, va_list ap)
{
    vout_display_sys_t *sys = vd->sys;

    switch (query)
    {
        case VOUT_DISPLAY_CHANGE_FULLSCREEN:
        {
            const vout_display_cfg_t *cfg = va_arg (ap, const vout_display_cfg_t *);
            if (vout_window_SetFullScreen (sys->embed, cfg->is_fullscreen))
                return VLC_EGENERIC;

            return VLC_SUCCESS;
        }
        case VOUT_DISPLAY_CHANGE_WINDOW_STATE:
        {
            NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];
            unsigned state = va_arg (ap, unsigned);
            [sys->glView performSelectorOnMainThread:@selector(setWindowLevel:) withObject:[NSNumber numberWithUnsignedInt:state] waitUntilDone:NO];
            [o_pool release];
            return VLC_SUCCESS;
        }
        case VOUT_DISPLAY_CHANGE_DISPLAY_FILLED:
        case VOUT_DISPLAY_CHANGE_ZOOM:
        case VOUT_DISPLAY_CHANGE_SOURCE_ASPECT:
        case VOUT_DISPLAY_CHANGE_SOURCE_CROP:
        case VOUT_DISPLAY_CHANGE_DISPLAY_SIZE:
        {
            if (!vd->sys)
                return VLC_EGENERIC;

            NSAutoreleasePool * o_pool = [[NSAutoreleasePool alloc] init];

            id o_window = [sys->glView window];
            if (!o_window)
                return VLC_SUCCESS; // this is okay, since the event will occur again when we have a window

            NSSize windowMinSize = [o_window minSize];

            const vout_display_cfg_t *cfg;
            const video_format_t *source;
            bool is_forced = false;

            vout_display_place_t place;

            if (query == VOUT_DISPLAY_CHANGE_SOURCE_ASPECT || query == VOUT_DISPLAY_CHANGE_SOURCE_CROP)
            {
                source = (const video_format_t *)va_arg (ap, const video_format_t *);
                cfg = vd->cfg;
            }
            else
            {
                source = &vd->source;
                cfg = (const vout_display_cfg_t*)va_arg (ap, const vout_display_cfg_t *);
                if (query == VOUT_DISPLAY_CHANGE_DISPLAY_SIZE)
                    is_forced = (bool)va_arg (ap, int);
            }

            if (query == VOUT_DISPLAY_CHANGE_DISPLAY_SIZE && is_forced
                && (cfg->display.width != vd->cfg->display.width
                    || cfg->display.height != vd->cfg->display.height)
                && vout_window_SetSize (sys->embed, cfg->display.width, cfg->display.height))
                return VLC_EGENERIC;
 
            /* for the case that the core wants to resize below minimum window size we correct the size here
             to ensure a centered picture */
            vout_display_cfg_t cfg_tmp = *cfg;
            if (cfg_tmp.display.width < windowMinSize.width)
                cfg_tmp.display.width = windowMinSize.width;
            if (cfg_tmp.display.height < 70)
                cfg_tmp.display.height = 70;

            if (!config_GetInt(vd, "macosx-video-autoresize"))
            {
                NSRect bounds = [sys->glView bounds];
                cfg_tmp.display.width = bounds.size.width;
                cfg_tmp.display.height = bounds.size.height;
            }

            vout_display_PlacePicture (&place, source, &cfg_tmp, false);

            /* For resize, we call glViewport in reshape and not here.
               This has the positive side effect that we avoid erratic sizing as we animate every resize. */
            if (query != VOUT_DISPLAY_CHANGE_DISPLAY_SIZE)
            {
                // x / y are top left corner, but we need the lower left one
                glViewport (place.x, cfg_tmp.display.height - (place.y + place.height), place.width, place.height);
            }

            [o_pool release];
            return VLC_SUCCESS;
        }

        case VOUT_DISPLAY_HIDE_MOUSE:
        {
            [NSCursor setHiddenUntilMouseMoves: YES];
            return VLC_SUCCESS;
        }

        case VOUT_DISPLAY_GET_OPENGL:
        {
            vlc_gl_t **gl = va_arg (ap, vlc_gl_t **);
            *gl = &sys->gl;
            return VLC_SUCCESS;
        }

        case VOUT_DISPLAY_RESET_PICTURES:
            assert (0);
        default:
            msg_Err (vd, "Unknown request in Mac OS X vout display");
            return VLC_EGENERIC;
    }
}

/*****************************************************************************
 * vout opengl callbacks
 *****************************************************************************/
static int OpenglLock (vlc_gl_t *gl)
{
    vout_display_sys_t *sys = (vout_display_sys_t *)gl->sys;
    NSOpenGLContext *context = [sys->glView openGLContext];
    CGLError err = CGLLockContext ([context CGLContextObj]);
    if (kCGLNoError == err)
    {
        [context makeCurrentContext];
        return 0;
    }
    return 1;
}

static void OpenglUnlock (vlc_gl_t *gl)
{
    vout_display_sys_t *sys = (vout_display_sys_t *)gl->sys;
    CGLUnlockContext ([[sys->glView openGLContext] CGLContextObj]);
}

static void OpenglSwap (vlc_gl_t *gl)
{
    vout_display_sys_t *sys = (vout_display_sys_t *)gl->sys;
    [[sys->glView openGLContext] flushBuffer];
}

/*****************************************************************************
 * Our NSView object
 *****************************************************************************/
@implementation VLCOpenGLVideoView

#define VLCAssertMainThread() assert([[NSThread currentThread] isMainThread])


+ (void)getNewView:(NSValue *)value
{
    id *ret = [value pointerValue];
    *ret = [[self alloc] init];
}

/**
 * Gets called by the Open() method.
 */
- (id)init
{
    VLCAssertMainThread();

    /* Warning - this may be called on non main thread */

    NSOpenGLPixelFormatAttribute attribs[] =
    {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFANoRecovery,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAWindow,
        0
    };

    NSOpenGLPixelFormat *fmt = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribs];

    if (!fmt)
        return nil;

    self = [super initWithFrame:NSMakeRect(0,0,10,10) pixelFormat:fmt];
    [fmt release];

    if (!self)
        return nil;

    /* Swap buffers only during the vertical retrace of the monitor.
     http://developer.apple.com/documentation/GraphicsImaging/
     Conceptual/OpenGL/chap5/chapter_5_section_44.html */
    GLint params[] = { 1 };
    CGLSetParameter ([[self openGLContext] CGLContextObj], kCGLCPSwapInterval, params);

    [self setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    return self;
}

/**
 * Gets called by the Open() method.
 */
- (void)setFrameWithValue:(NSValue *)value
{
    [self setFrame:[value rectValue]];
}

/**
 * Gets called by the Close and Open methods.
 * (Non main thread).
 */
- (void)setVoutDisplay:(vout_display_t *)aVd
{
    @synchronized(self) {
        vd = aVd;
    }
}

- (vout_display_t *)voutDisplay
{
    return vd;
}

/**
 * Gets called when the vout will aquire the lock and flush.
 * (Non main thread).
 */
- (void)setVoutFlushing:(BOOL)flushing
{
    if (!flushing)
        return;
    @synchronized(self) {
        _hasPendingReshape = NO;
    }
}

/**
 * Can -drawRect skip rendering?.
 */
- (BOOL)canSkipRendering
{
    VLCAssertMainThread();

    @synchronized(self) {
        BOOL hasFirstFrame = vd && vd->sys->has_first_frame;
        return !_hasPendingReshape && hasFirstFrame;
    }
}


/**
 * Local method that locks the gl context.
 */
- (BOOL)lockgl
{
    VLCAssertMainThread();
    NSOpenGLContext *context = [self openGLContext];
    CGLError err = CGLLockContext ([context CGLContextObj]);
    if (err == kCGLNoError)
        [context makeCurrentContext];
    return err == kCGLNoError;
}

/**
 * Local method that unlocks the gl context.
 */
- (void)unlockgl
{
    VLCAssertMainThread();
    CGLUnlockContext ([[self openGLContext] CGLContextObj]);
}

/**
 * Local method that force a rendering of a frame.
 * This will get called if Cocoa forces us to redraw (via -drawRect).
 */
- (void)render
{
    VLCAssertMainThread();

    // We may have taken some times to take the opengl Lock.
    // Check here to see if we can just skip the frame as well.
    if ([self canSkipRendering])
        return;

    BOOL hasFirstFrame;
    @synchronized(self) { // vd can be accessed from multiple threads
        hasFirstFrame = vd && vd->sys->has_first_frame;
    }

    if (hasFirstFrame) {
        // This will lock gl.
        vout_display_opengl_Display (vd->sys->vgl, &vd->source);
    }
    else
        glClear (GL_COLOR_BUFFER_BIT);
}

/**
 * Method called by Cocoa when the view is resized.
 */
- (void)reshape
{
    VLCAssertMainThread();

    NSRect bounds = [self bounds];
    vout_display_place_t place;

    @synchronized(self) {
        if (vd) {
            vout_display_cfg_t cfg_tmp = *(vd->cfg);
            cfg_tmp.display.width  = bounds.size.width;
            cfg_tmp.display.height = bounds.size.height;

            vout_display_PlacePicture (&place, &vd->source, &cfg_tmp, false);
            vout_display_SendEventDisplaySize (vd, bounds.size.width, bounds.size.height, vd->cfg->is_fullscreen);
        }
    }

    if ([self lockgl]) {
        // x / y are top left corner, but we need the lower left one
        glViewport (place.x, bounds.size.height - (place.y + place.height), place.width, place.height);

        @synchronized(self) {
            // This may be cleared before -drawRect is being called,
            // in this case we'll skip the rendering.
            // This will save us for rendering two frames (or more) for nothing
            // (one by the vout, one (or more) by drawRect)
            _hasPendingReshape = YES;
        }

        [self unlockgl];

        [super reshape];
    }
}

/**
 * Method called by Cocoa when the view is resized or the location has changed.
 * We just need to make sure we are locking here.
 */
- (void)update
{
    VLCAssertMainThread();
    BOOL success = [self lockgl];
    if (!success)
        return;

    [super update];

    [self unlockgl];
}

/**
 * Method called by Cocoa to force redraw.
 */
- (void)drawRect:(NSRect) rect
{
    VLCAssertMainThread();

    if ([self canSkipRendering])
        return;

    BOOL success = [self lockgl];
    if (!success)
        return;

    [self render];

    [self unlockgl];
}

- (void)renewGState
{
    NSWindow *window = [self window];

    // Remove flashes with splitter view.
    if ([window respondsToSelector:@selector(disableScreenUpdatesUntilFlush)])
        [window disableScreenUpdatesUntilFlush];

    [super renewGState];
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)setWindowLevel:(NSNumber*)state
{
    if ([state unsignedIntValue] & VOUT_WINDOW_STATE_ABOVE)
        [[self window] setLevel: NSStatusWindowLevel];
    else
        [[self window] setLevel: NSNormalWindowLevel];
}

#pragma mark -
#pragma mark Mouse handling

- (void)mouseDown:(NSEvent *)o_event
{
    if ([o_event type] == NSLeftMouseDown && !([o_event modifierFlags] &  NSControlKeyMask))
    {
        if ([o_event clickCount] <= 1)
            vout_display_SendEventMousePressed (vd, MOUSE_BUTTON_LEFT);
    }

    [super mouseDown:o_event];
}

- (void)otherMouseDown:(NSEvent *)o_event
{
    vout_display_SendEventMousePressed (vd, MOUSE_BUTTON_CENTER);

    [super otherMouseDown: o_event];
}

- (void)mouseUp:(NSEvent *)o_event
{
    if ([o_event type] == NSLeftMouseUp)
        vout_display_SendEventMouseReleased (vd, MOUSE_BUTTON_LEFT);

    [super mouseUp: o_event];
}

- (void)otherMouseUp:(NSEvent *)o_event
{
    vout_display_SendEventMouseReleased (vd, MOUSE_BUTTON_CENTER);

    [super otherMouseUp: o_event];
}

- (void)mouseMoved:(NSEvent *)o_event
{
    NSPoint ml;
    NSRect s_rect;
    BOOL b_inside;

    s_rect = [self bounds];
    ml = [self convertPoint: [o_event locationInWindow] fromView: nil];
    b_inside = [self mouse: ml inRect: s_rect];

    if (b_inside)
    {
        vout_display_place_t place;
        vout_display_PlacePicture (&place, &vd->source, vd->cfg, false);

        if (place.width > 0 && place.height > 0)
        {
            const int x = vd->source.i_x_offset +
            (int64_t)(ml.x - place.x) * vd->source.i_visible_width / place.width;
            const int y = vd->source.i_y_offset +
            (int64_t)((int)s_rect.size.height - (int)ml.y - place.y) * vd->source.i_visible_height / place.height;

            vout_display_SendEventMouseMoved (vd, x, y);
        }
    }

    [super mouseMoved: o_event];
}

- (void)mouseDragged:(NSEvent *)o_event
{
    [self mouseMoved: o_event];
    [super mouseDragged: o_event];
}

- (void)otherMouseDragged:(NSEvent *)o_event
{
    [self mouseMoved: o_event];
    [super otherMouseDragged: o_event];
}

- (void)rightMouseDragged:(NSEvent *)o_event
{
    [self mouseMoved: o_event];
    [super rightMouseDragged: o_event];
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)mouseDownCanMoveWindow
{
    return YES;
}

@end
