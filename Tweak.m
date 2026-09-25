// MLBBESP — Internal ESP dylib for Mobile Legends (iOS)
// Debug build: multi-assembly search + live debug HUD.

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <dlfcn.h>
#import <pthread.h>
#import <unistd.h>
#import <string.h>
#import <math.h>

// ---- offsets (IL2CPP v29, MLBB 2.2.16) ----
#define O_LIST_ITEMS            0x10
#define O_LIST_SIZE             0x18
#define O_ARRAY_LENGTH          0x18
#define O_ARRAY_DATA            0x20
#define O_STRING_LENGTH         0x10
#define O_STRING_CHARS          0x14

#define SE_IsPlayer             0x93
#define SE_m_bDeath             0xCD
#define SE_m_EntityCampType     0xD8
#define SE_m_Level              0x198
#define SE_m_Hp                 0x1AC
#define SE_m_HpMax              0x1B0
#define SE_m_bSelf              0x250
#define SE_m_vUnityCachePos     0x2A0
#define SE_m_RoleName           0x468

#define SP_m_HeroName           0x8F8

#define BM_m_ShowPlayers        0x78
#define GM_mainCamera           0x10
#define SF_m_CameraCurrentPos   0x1E4

#define CAM_PITCH_DEG   54.736f
#define CAM_FOV_DEG     40.0f
#define HERO_HEIGHT     2.2f
#define MAX_ENTITIES    16

// ---- forward declarations ----
@interface ESPMenuController : NSObject
+ (instancetype)shared;
- (void)togglePanel;
- (void)setupWithKeyWindow:(UIWindow*)keyWindow;
@end

// ---- IL2CPP API ----
typedef void* Il2CppDomain;
typedef void* Il2CppAssembly;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppFieldInfo;

static bool              (*p_vm_running)(void);
static Il2CppDomain*     (*p_domain_get)(void);
static const Il2CppAssembly** (*p_domain_get_assemblies)(const Il2CppDomain*, size_t*);
static Il2CppImage*      (*p_assembly_get_image)(const Il2CppAssembly*);
static const char*       (*p_image_get_name)(const Il2CppImage*);
static size_t            (*p_image_get_class_count)(const Il2CppImage*);
static Il2CppClass*      (*p_image_get_class)(const Il2CppImage*, size_t);
static const char*       (*p_class_get_name)(const Il2CppClass*);
static Il2CppFieldInfo*  (*p_class_get_field_from_name)(const Il2CppClass*, const char*);
static void              (*p_field_static_get_value)(Il2CppFieldInfo*, void*);
static void*             (*p_thread_attach)(Il2CppDomain*);

static bool g_il2cpp_ready = false;
static Il2CppClass* g_bm_class = NULL;
static Il2CppClass* g_gm_class = NULL;

static bool init_il2cpp(void) {
    p_vm_running                = dlsym(RTLD_DEFAULT, "il2cpp_is_vm_running");
    p_domain_get                = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    p_domain_get_assemblies     = dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    p_assembly_get_image        = dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    p_image_get_name            = dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    p_image_get_class_count     = dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    p_image_get_class           = dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    p_class_get_name            = dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    p_class_get_field_from_name = dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
    p_field_static_get_value    = dlsym(RTLD_DEFAULT, "il2cpp_field_static_get_value");
    p_thread_attach             = dlsym(RTLD_DEFAULT, "il2cpp_thread_attach");
    if (!p_vm_running || !p_domain_get || !p_domain_get_assemblies ||
        !p_assembly_get_image || !p_image_get_name ||
        !p_image_get_class_count || !p_image_get_class || !p_class_get_name ||
        !p_class_get_field_from_name || !p_field_static_get_value ||
        !p_thread_attach) return false;
    return true;
}

// ---- crash-proof memory reads ----
static bool safe_read(uintptr_t addr, void* buf, size_t len) {
    if (addr == 0 || len == 0) return false;
    vm_size_t out = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)addr,
                                         (vm_size_t)len,
                                         (vm_address_t)buf,
                                         &out);
    return (kr == KERN_SUCCESS && out == len);
}

// ---- helpers ----
typedef struct { float x, y, z; } vec3;

typedef struct {
    char name[64];
    char hero[64];
    float sx, sy, bw, bh;
    int hp, hpmax;
    int camp, level;
    bool is_dead, is_self, is_visible;
} ESPEntityData;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static ESPEntityData g_entities[MAX_ENTITIES];
static int g_entity_count = 0;
static vec3 g_cam_pos = {0};
static float g_screen_w = 0, g_screen_h = 0;

// ---- ESP settings ----
static volatile bool g_esp_enabled = false;
static volatile bool g_show_names = true;
static volatile bool g_show_hp = true;
static volatile bool g_show_dead = false;
static volatile bool g_show_debug = true;

// ---- live debug state ----
static volatile int  g_st_il2cpp        = 0;
static volatile int  g_st_bm            = 0;
static volatile int  g_st_gm            = 0;
static volatile int  g_st_inst          = 0;
static volatile int  g_st_list          = -1;
static volatile int  g_st_proj          = 0;
static volatile int  g_st_cam           = 0;
static volatile int  g_st_tries         = 0;
static float         g_st_campx         = 0, g_st_campy = 0, g_st_campz = 0;
static char          g_st_bm_img[64]    = "?";

static int32_t read_i32(uintptr_t a) { int32_t v=0; safe_read(a,&v,4); return v; }
static bool read_bool(uintptr_t a) { uint8_t v=0; safe_read(a,&v,1); return v!=0; }
static uintptr_t read_ptr(uintptr_t a) { uintptr_t v=0; safe_read(a,&v,sizeof(v)); return v; }

static vec3 read_vec3(uintptr_t a) {
    vec3 v = {0};
    safe_read(a, &v, sizeof(v));
    return v;
}

static void read_string(uintptr_t str_ptr, char* out, int max_len) {
    out[0] = '\0';
    if (str_ptr == 0) return;
    int32_t len = 0;
    if (!safe_read(str_ptr + O_STRING_LENGTH, &len, 4)) return;
    if (len <= 0 || len > 256) return;
    int rl = (len < max_len - 1) ? len : (max_len - 1);
    uint16_t chars[256];
    if (!safe_read(str_ptr + O_STRING_CHARS, chars, rl * sizeof(uint16_t))) return;
    int j = 0;
    for (int i = 0; i < rl && j < max_len - 1; i++) {
        if (chars[i] < 0x80) out[j++] = (char)chars[i];
        else if (chars[i] < 0x800) {
            out[j++] = (char)(0xC0 | (chars[i] >> 6));
            out[j++] = (char)(0x80 | (chars[i] & 0x3F));
        } else {
            out[j++] = (char)(0xE0 | (chars[i] >> 12));
            out[j++] = (char)(0x80 | ((chars[i] >> 6) & 0x3F));
            out[j++] = (char)(0x80 | (chars[i] & 0x3F));
        }
    }
    out[j] = '\0';
}

// ---- class resolution: search ALL assemblies ----
static Il2CppClass* find_class_anywhere(const char* target, const char* required_field, char* found_img, int img_max) {
    if (!g_il2cpp_ready) return NULL;
    Il2CppDomain* domain = p_domain_get();
    if (domain == NULL) return NULL;

    size_t asm_count = 0;
    const Il2CppAssembly** assemblies = p_domain_get_assemblies(domain, &asm_count);
    if (assemblies == NULL) return NULL;

    for (size_t a = 0; a < asm_count; a++) {
        Il2CppImage* image = p_assembly_get_image(assemblies[a]);
        if (image == NULL) continue;

        const char* img_name = p_image_get_name(image);
        if (img_name == NULL) continue;

        size_t cc = p_image_get_class_count(image);
        if (cc == 0 || cc > 200000) continue;

        for (size_t c = 0; c < cc; c++) {
            Il2CppClass* klass = p_image_get_class(image, c);
            if (klass == NULL) continue;
            const char* name = p_class_get_name(klass);
            if (name != NULL && strcmp(name, target) == 0) {
                if (found_img != NULL) {
                    strncpy(found_img, img_name, img_max - 1);
                    found_img[img_max - 1] = '\0';
                }
                if (p_class_get_field_from_name(klass, required_field) != NULL) return klass;
            }
        }
    }
    return NULL;
}

static bool resolve_classes(void) {
    if (g_bm_class == NULL) {
        g_bm_class = find_class_anywhere("BattleManager", "m_ShowPlayers", g_st_bm_img, sizeof(g_st_bm_img));
        if (g_bm_class != NULL) g_st_bm = 1;
    }
    if (g_gm_class == NULL) {
        g_gm_class = find_class_anywhere("GameMethod", "mainCamera", NULL, 0);
        if (g_gm_class != NULL) g_st_gm = 1;
    }
    return (g_bm_class != NULL);
}

static uintptr_t get_bm_instance(void) {
    if (g_bm_class == NULL) return 0;
    Il2CppFieldInfo* f = p_class_get_field_from_name(g_bm_class, "Instance");
    if (f == NULL) return 0;
    void* v = NULL;
    p_field_static_get_value(f, &v);
    return (uintptr_t)v;
}

static uintptr_t get_gm_mainCamera(void) {
    if (g_gm_class == NULL) return 0;
    Il2CppFieldInfo* f = p_class_get_field_from_name(g_gm_class, "mainCamera");
    if (f == NULL) return 0;
    void* v = NULL;
    p_field_static_get_value(f, &v);
    return (uintptr_t)v;
}

// ---- projection ----
static bool project_to_screen(vec3 world, float* sx, float* sy) {
    if (g_cam_pos.x == 0 && g_cam_pos.y == 0 && g_cam_pos.z == 0) return false;
    float pitch = CAM_PITCH_DEG * (float)M_PI / 180.0f;
    vec3 forward = { 0.0f, -sinf(pitch), cosf(pitch) };
    vec3 right   = { 1.0f, 0.0f, 0.0f };
    vec3 up      = { 0.0f, cosf(pitch), sinf(pitch) };
    vec3 rel = { world.x - g_cam_pos.x, world.y - g_cam_pos.y, world.z - g_cam_pos.z };
    float cx = rel.x*right.x + rel.y*right.y + rel.z*right.z;
    float cy = rel.x*up.x    + rel.y*up.y    + rel.z*up.z;
    float cz = rel.x*forward.x + rel.y*forward.y + rel.z*forward.z;
    if (cz < 0.5f) return false;
    float fov = CAM_FOV_DEG * (float)M_PI / 180.0f;
    float f = 1.0f / tanf(fov * 0.5f);
    float aspect = g_screen_w / g_screen_h;
    float ndc_x = (cx / cz) * f / aspect;
    float ndc_y = (cy / cz) * f;
    *sx = (ndc_x + 1.0f) * 0.5f * g_screen_w;
    *sy = (1.0f - ndc_y) * 0.5f * g_screen_h;
    return true;
}

// ---- entity reading ----
static void read_all_entities(void) {
    pthread_mutex_lock(&g_lock);
    g_entity_count = 0;
    pthread_mutex_unlock(&g_lock);

    g_st_proj = 0;
    if (!g_il2cpp_ready || g_bm_class == NULL) return;
    if (!g_esp_enabled) return;

    uintptr_t bm = get_bm_instance();
    g_st_inst = (bm != 0) ? 1 : 0;
    if (bm == 0) return;

    uintptr_t sf = get_gm_mainCamera();
    if (sf != 0) {
        g_cam_pos = read_vec3(sf + SF_m_CameraCurrentPos);
        g_st_cam = 1;
        g_st_campx = g_cam_pos.x; g_st_campy = g_cam_pos.y; g_st_campz = g_cam_pos.z;
    } else {
        g_st_cam = 0;
    }

    uintptr_t list = read_ptr(bm + BM_m_ShowPlayers);
    if (list == 0) { g_st_list = -1; return; }
    uintptr_t arr = read_ptr(list + O_LIST_ITEMS);
    if (arr == 0) { g_st_list = -2; return; }

    int32_t count = read_i32(arr + O_ARRAY_LENGTH);
    int32_t list_size = read_i32(list + O_LIST_SIZE);
    g_st_list = list_size;
    if (list_size >= 0 && list_size < count) count = list_size;
    if (count <= 0) return;
    if (count > MAX_ENTITIES) count = MAX_ENTITIES;

    uintptr_t ents[MAX_ENTITIES];
    if (!safe_read(arr + O_ARRAY_DATA, ents, count * sizeof(uintptr_t))) return;

    ESPEntityData local[MAX_ENTITIES];
    int n = 0;
    int projected = 0;
    for (int i = 0; i < count && n < MAX_ENTITIES; i++) {
        uintptr_t ep = ents[i];
        if (ep == 0) continue;

        uint8_t probe = 0;
        if (!safe_read(ep, &probe, 1)) continue;

        ESPEntityData* e = &local[n];
        memset(e, 0, sizeof(ESPEntityData));

        e->is_dead = read_bool(ep + SE_m_bDeath);
        e->camp    = read_i32(ep + SE_m_EntityCampType);
        e->hp      = read_i32(ep + SE_m_Hp);
        e->hpmax   = read_i32(ep + SE_m_HpMax);
        e->level   = read_i32(ep + SE_m_Level);
        e->is_self = read_bool(ep + SE_m_bSelf);

        read_string(read_ptr(ep + SE_m_RoleName), e->name, sizeof(e->name));

        bool is_player = read_bool(ep + SE_IsPlayer);
        if (is_player) {
            read_string(read_ptr(ep + SP_m_HeroName), e->hero, sizeof(e->hero));
        }

        vec3 world = read_vec3(ep + SE_m_vUnityCachePos);
        if (world.x == 0 && world.y == 0 && world.z == 0) continue;

        float fx, fy, hx, hy;
        vec3 feet = world;
        vec3 head = { world.x, world.y + HERO_HEIGHT, world.z };
        bool pf = project_to_screen(feet, &fx, &fy);
        bool ph = project_to_screen(head, &hx, &hy);
        if (!pf || !ph) continue;
        projected++;

        float bh = fabsf(fy - hy);
        if (bh < 4.0f) bh = 4.0f;
        float bw = bh * 0.55f;
        e->sx = hx - bw / 2.0f;
        e->sy = hy;
        e->bw = bw;
        e->bh = bh;
        e->is_visible = true;
        n++;
    }

    pthread_mutex_lock(&g_lock);
    memcpy(g_entities, local, n * sizeof(ESPEntityData));
    g_entity_count = n;
    pthread_mutex_unlock(&g_lock);
    g_st_proj = projected;
}

static void* reader_thread(void* arg) {
    (void)arg;

    int waits = 0;
    while (waits < 600) {
        if (g_il2cpp_ready) break;
        if (init_il2cpp() && p_vm_running()) {
            g_il2cpp_ready = true;
            g_st_il2cpp = 1;
            break;
        }
        waits++;
        usleep(1000000);
    }
    if (!g_il2cpp_ready) return NULL;
    NSLog(@"[MLBBESP] IL2CPP VM running, API ready");

    Il2CppDomain* domain = p_domain_get();
    if (domain == NULL) return NULL;
    if (p_thread_attach(domain) == NULL) {
        NSLog(@"[MLBBESP] thread attach failed");
        return NULL;
    }

    int attempts = 0;
    while (!resolve_classes() && attempts < 300) {
        attempts++;
        g_st_tries = attempts;
        usleep(2000000);
    }
    if (g_bm_class == NULL) { NSLog(@"[MLBBESP] BattleManager not found"); return NULL; }
    NSLog(@"[MLBBESP] Classes resolved");

    while (true) {
        @autoreleasepool { read_all_entities(); }
        usleep(33333);
    }
    return NULL;
}

// ===========================================================================
// ESP OVERLAY VIEW
// ===========================================================================

@interface ESPOverlayView : UIView
@property (strong, nonatomic) CADisplayLink* link;
@end

@implementation ESPOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        self.link.preferredFramesPerSecond = 30;
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)tick:(CADisplayLink*)l {
    (void)l;
    [self setNeedsDisplay];
}

- (void)drawDebugHUD:(CGContextRef)ctx {
    char lines[10][96];
    int n = 0;
    snprintf(lines[n++], 96, "il2cpp: %s", g_st_il2cpp ? "OK" : "waiting...");
    snprintf(lines[n++], 96, "tries: %d", g_st_tries);
    snprintf(lines[n++], 96, "BattleManager: %s (%s)", g_st_bm ? "OK" : "NOT FOUND", g_st_bm_img);
    snprintf(lines[n++], 96, "GameMethod: %s", g_st_gm ? "OK" : "NOT FOUND");
    snprintf(lines[n++], 96, "Instance: %s", g_st_inst ? "OK" : "null");
    snprintf(lines[n++], 96, "cam: %s (%.0f,%.0f,%.0f)", g_st_cam ? "OK" : "FAIL", g_st_campx, g_st_campy, g_st_campz);
    snprintf(lines[n++], 96, "list count: %d", g_st_list);
    snprintf(lines[n++], 96, "projected: %d", g_st_proj);
    snprintf(lines[n++], 96, "esp: %s", g_esp_enabled ? "ON" : "OFF");

    UIFont* font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
    CGContextFillRect(ctx, CGRectMake(4, 60, 230, 14 * n + 8));

    for (int i = 0; i < n; i++) {
        NSString* s = [NSString stringWithUTF8String:lines[i]];
        NSDictionary* attrs = @{ NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: [UIColor greenColor] };
        [s drawAtPoint:CGPointMake(8, 64 + i * 14) withAttributes:attrs];
    }
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx == NULL) return;

    if (g_show_debug) [self drawDebugHUD:ctx];
    if (!g_esp_enabled) return;

    ESPEntityData ents[MAX_ENTITIES];
    int count = 0;
    pthread_mutex_lock(&g_lock);
    count = g_entity_count;
    if (count > 0) memcpy(ents, g_entities, count * sizeof(ESPEntityData));
    pthread_mutex_unlock(&g_lock);
    if (count == 0) return;

    for (int i = 0; i < count; i++) {
        ESPEntityData* e = &ents[i];
        if (e->is_self) continue;
        if (e->is_dead && !g_show_dead) continue;

        UIColor* box_color;
        if (e->camp == 1) box_color = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:1.0];
        else if (e->camp == 2) box_color = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0];
        else box_color = [UIColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0];

        CGRect box = CGRectMake(e->sx, e->sy, e->bw, e->bh);
        CGContextSetStrokeColorWithColor(ctx, box_color.CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextStrokeRect(ctx, box);

        if (g_show_hp && e->hpmax > 0) {
            float ratio = (float)e->hp / (float)e->hpmax;
            if (ratio < 0.0f) ratio = 0.0f;
            if (ratio > 1.0f) ratio = 1.0f;
            CGRect bg = CGRectMake(box.origin.x, box.origin.y - 6, box.size.width, 4);
            CGRect fg = CGRectMake(bg.origin.x, bg.origin.y, bg.size.width * ratio, bg.size.height);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.1 alpha:0.8].CGColor);
            CGContextFillRect(ctx, bg);
            UIColor* hc = ratio > 0.3f ? [UIColor colorWithRed:0 green:0.9 blue:0.2 alpha:1]
                                        : [UIColor colorWithRed:1 green:0.1 blue:0.1 alpha:1];
            CGContextSetFillColorWithColor(ctx, hc.CGColor);
            CGContextFillRect(ctx, fg);
        }

        if (e->is_dead) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor grayColor].CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextMoveToPoint(ctx, box.origin.x, box.origin.y);
            CGContextAddLineToPoint(ctx, box.origin.x+box.size.width, box.origin.y+box.size.height);
            CGContextMoveToPoint(ctx, box.origin.x+box.size.width, box.origin.y);
            CGContextAddLineToPoint(ctx, box.origin.x, box.origin.y+box.size.height);
            CGContextStrokePath(ctx);
        }

        if (g_show_names) {
            const char* display = (e->hero[0] != '\0') ? e->hero : e->name;
            NSString* label = [NSString stringWithFormat:@"%s [%d]", display, e->level];
            UIFont* font = [UIFont boldSystemFontOfSize:10];
            NSDictionary* attrs = @{ NSFontAttributeName: font,
                                     NSForegroundColorAttributeName: [UIColor whiteColor] };
            CGSize ts = [label sizeWithAttributes:attrs];
            CGPoint tp = CGPointMake(box.origin.x + (box.size.width - ts.width)/2.0f,
                                     box.origin.y + box.size.height + 3);
            CGContextSetShadowWithColor(ctx, CGSizeMake(1,1), 1, [UIColor blackColor].CGColor);
            [label drawAtPoint:tp withAttributes:attrs];
            CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
        }
    }
}

- (void)dealloc { [self.link invalidate]; }

@end

// ===========================================================================
// SETTINGS PANEL
// ===========================================================================

@interface SettingsPanel : UIView
@end

@implementation SettingsPanel

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1].CGColor;
        self.clipsToBounds = YES;

        UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 24)];
        title.text = @"MLBB ESP";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:16];
        [self addSubview:title];

        float w = frame.size.width;

        UILabel* l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 50, 150, 20)];
        l1.text = @"ESP Enabled"; l1.textColor = [UIColor lightGrayColor]; l1.font = [UIFont systemFontOfSize:13];
        [self addSubview:l1];
        UISwitch* s1 = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 46, 0, 0)];
        s1.on = g_esp_enabled; s1.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [s1 addTarget:self action:@selector(espToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:s1];

        UILabel* l2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 92, 150, 20)];
        l2.text = @"Show Names"; l2.textColor = [UIColor lightGrayColor]; l2.font = [UIFont systemFontOfSize:13];
        [self addSubview:l2];
        UISwitch* s2 = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 88, 0, 0)];
        s2.on = g_show_names; s2.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [s2 addTarget:self action:@selector(namesToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:s2];

        UILabel* l3 = [[UILabel alloc] initWithFrame:CGRectMake(16, 134, 150, 20)];
        l3.text = @"Show HP Bar"; l3.textColor = [UIColor lightGrayColor]; l3.font = [UIFont systemFontOfSize:13];
        [self addSubview:l3];
        UISwitch* s3 = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 130, 0, 0)];
        s3.on = g_show_hp; s3.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [s3 addTarget:self action:@selector(hpToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:s3];

        UILabel* l4 = [[UILabel alloc] initWithFrame:CGRectMake(16, 176, 150, 20)];
        l4.text = @"Show Dead"; l4.textColor = [UIColor lightGrayColor]; l4.font = [UIFont systemFontOfSize:13];
        [self addSubview:l4];
        UISwitch* s4 = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 172, 0, 0)];
        s4.on = g_show_dead; s4.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [s4 addTarget:self action:@selector(deadToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:s4];

        UILabel* l5 = [[UILabel alloc] initWithFrame:CGRectMake(16, 218, 150, 20)];
        l5.text = @"Debug HUD"; l5.textColor = [UIColor lightGrayColor]; l5.font = [UIFont systemFontOfSize:13];
        [self addSubview:l5];
        UISwitch* s5 = [[UISwitch alloc] initWithFrame:CGRectMake(w - 70, 214, 0, 0)];
        s5.on = g_show_debug; s5.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [s5 addTarget:self action:@selector(debugToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:s5];

        UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(16, 256, w - 32, 36);
        [closeBtn setTitle:@"Close" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
        closeBtn.layer.cornerRadius = 8;
        [closeBtn addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeBtn];
    }
    return self;
}

- (void)espToggled:(UISwitch*)s   { g_esp_enabled = s.on; }
- (void)namesToggled:(UISwitch*)s { g_show_names = s.on; }
- (void)hpToggled:(UISwitch*)s    { g_show_hp = s.on; }
- (void)deadToggled:(UISwitch*)s  { g_show_dead = s.on; }
- (void)debugToggled:(UISwitch*)s { g_show_debug = s.on; }

- (void)closeTapped {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"MLBBESP_ClosePanel" object:nil];
}

@end

// ===========================================================================
// FLOATING BUTTON
// ===========================================================================

@interface FloatingButton : UIButton
@property (strong, nonatomic) UIPanGestureRecognizer* pan;
@property (assign, nonatomic) CGPoint gestureStartCenter;
@property (assign, nonatomic) bool moved;
@end

@implementation FloatingButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1].CGColor;
        [self setTitle:@"ESP" forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [self setTitleColor:[UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1] forState:UIControlStateNormal];

        self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:self.pan];
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        self.moved = false;
    }
    return self;
}

- (void)onPan:(UIPanGestureRecognizer*)gr {
    CGPoint translation = [gr translationInView:nil];
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.gestureStartCenter = self.window.center;
        self.moved = false;
    }
    if (gr.state == UIGestureRecognizerStateChanged) {
        if (fabs(translation.x) > 4 || fabs(translation.y) > 4) self.moved = true;
        CGPoint newCenter = CGPointMake(self.gestureStartCenter.x + translation.x,
                                        self.gestureStartCenter.y + translation.y);
        CGRect screen = UIScreen.mainScreen.bounds;
        CGFloat half = self.window.frame.size.width / 2.0;
        newCenter.x = MAX(half, MIN(screen.size.width - half, newCenter.x));
        newCenter.y = MAX(half, MIN(screen.size.height - half, newCenter.y));
        self.window.center = newCenter;
    }
    if (gr.state == UIGestureRecognizerStateEnded) {
        CGRect screen = UIScreen.mainScreen.bounds;
        CGFloat half = self.window.frame.size.width / 2.0;
        CGFloat targetX;
        if (self.window.center.x < screen.size.width / 2.0) {
            targetX = half + 8;
        } else {
            targetX = screen.size.width - half - 8;
        }
        [UIView animateWithDuration:0.2 animations:^{
            self.window.center = CGPointMake(targetX, self.window.center.y);
        }];
    }
}

- (void)tapped {
    if (self.moved) return;
    [[ESPMenuController shared] togglePanel];
}

@end

// ===========================================================================
// MENU CONTROLLER
// ===========================================================================

@interface ESPMenuController ()
@property (strong, nonatomic) UIWindow* btnWindow;
@property (strong, nonatomic) UIWindow* panelWindow;
@property (strong, nonatomic) FloatingButton* floatingBtn;
@property (strong, nonatomic) SettingsPanel* panel;
@property (assign, nonatomic) bool panelVisible;
@end

@implementation ESPMenuController

+ (instancetype)shared {
    static ESPMenuController* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ESPMenuController alloc] init];
    });
    return instance;
}

- (void)setupWithKeyWindow:(UIWindow*)keyWindow {
    if (self.btnWindow != nil) return;

    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        UIWindowScene* scene = nil;
        if (@available(iOS 13.0, *)) scene = keyWindow.windowScene;

        CGFloat btnSize = 52;
        CGRect btnFrame = CGRectMake(screen.size.width - btnSize - 12,
                                     screen.size.height * 0.25, btnSize, btnSize);
        self.btnWindow = [[UIWindow alloc] initWithFrame:btnFrame];
        if (scene != nil) self.btnWindow.windowScene = scene;
        self.btnWindow.windowLevel = UIWindowLevelAlert + 1000;
        self.btnWindow.backgroundColor = [UIColor clearColor];
        self.btnWindow.userInteractionEnabled = YES;
        self.floatingBtn = [[FloatingButton alloc] initWithFrame:self.btnWindow.bounds];
        [self.btnWindow addSubview:self.floatingBtn];
        self.btnWindow.hidden = NO;

        CGFloat panelW = 260, panelH = 306;
        CGRect panelFrame = CGRectMake((screen.size.width - panelW) / 2.0,
                                       (screen.size.height - panelH) / 2.0,
                                       panelW, panelH);
        self.panelWindow = [[UIWindow alloc] initWithFrame:panelFrame];
        if (scene != nil) self.panelWindow.windowScene = scene;
        self.panelWindow.windowLevel = UIWindowLevelAlert + 1001;
        self.panelWindow.backgroundColor = [UIColor clearColor];
        self.panelWindow.userInteractionEnabled = YES;
        self.panel = [[SettingsPanel alloc] initWithFrame:self.panelWindow.bounds];
        [self.panelWindow addSubview:self.panel];
        self.panelWindow.hidden = YES;

        self.panelVisible = false;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(hidePanel)
                                                     name:@"MLBBESP_ClosePanel"
                                                   object:nil];

        NSLog(@"[MLBBESP] Control windows ready");
    }
    @catch (NSException* ex) {
        NSLog(@"[MLBBESP] setup exception: %@", ex);
        self.btnWindow = nil;
        self.panelWindow = nil;
    }
}

- (void)togglePanel {
    if (self.panelVisible) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel {
    if (self.panelWindow == nil) return;
    self.panel.alpha = 1;
    self.panel.transform = CGAffineTransformIdentity;
    self.panelWindow.hidden = NO;
    self.panelVisible = true;
}

- (void)hidePanel {
    if (self.panelWindow == nil) return;
    self.panelWindow.hidden = YES;
    self.panelVisible = false;
}

@end

// ===========================================================================
// ESP OVERLAY WINDOW
// ===========================================================================

static UIWindow* g_overlay_window = nil;
static ESPOverlayView* g_overlay_view = nil;

static void create_overlay(UIWindow* key) {
    if (g_overlay_window != nil) return;

    @try {
        CGRect b = UIScreen.mainScreen.bounds;
        g_screen_w = b.size.width;
        g_screen_h = b.size.height;

        g_overlay_window = [[UIWindow alloc] initWithFrame:b];
        if (@available(iOS 13.0, *)) g_overlay_window.windowScene = key.windowScene;
        g_overlay_window.windowLevel = UIWindowLevelAlert + 999;
        g_overlay_window.backgroundColor = [UIColor clearColor];
        g_overlay_window.userInteractionEnabled = NO;

        g_overlay_view = [[ESPOverlayView alloc] initWithFrame:b];
        g_overlay_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_overlay_window addSubview:g_overlay_view];
        g_overlay_window.hidden = NO;
        NSLog(@"[MLBBESP] Overlay ready (%.0f x %.0f)", g_screen_w, g_screen_h);
    }
    @catch (NSException* ex) {
        NSLog(@"[MLBBESP] overlay exception: %@", ex);
        g_overlay_window = nil;
    }
}

static void poll_windows(void);

static void poll_windows(void) {
    static int polls = 0;
    if (g_overlay_window != nil) return;
    if (polls > 180) return;
    polls++;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow* key = nil;
        for (UIWindow* w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow && w.rootViewController != nil) { key = w; break; }
        }
        if (key == nil) {
            poll_windows();
            return;
        }

        create_overlay(key);
        [[ESPMenuController shared] setupWithKeyWindow:key];
    });
}

// ===========================================================================
// CONSTRUCTOR
// ===========================================================================

__attribute__((constructor))
static void MLBBESP_init(void) {
    NSLog(@"[MLBBESP] Loaded");
    pthread_t t;
    pthread_create(&t, NULL, reader_thread, NULL);
    pthread_detach(t);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ poll_windows(); });
}
