#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <string.h>
#import <math.h>

// ---- offsets (IL2CPP v29, MLBB 2.2.16) ----
#define O_LIST_ITEMS            0x10
#define O_ARRAY_LENGTH          0x18
#define O_ARRAY_DATA            0x20
#define O_STRING_LENGTH         0x10
#define O_STRING_CHARS          0x14

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

// ---- IL2CPP API ----
typedef void* Il2CppDomain;
typedef void* Il2CppAssembly;
typedef void* Il2CppImage;
typedef void* Il2CppClass;
typedef void* Il2CppFieldInfo;

static Il2CppDomain* (*p_domain_get)(void);
static const Il2CppAssembly** (*p_domain_get_assemblies)(const Il2CppDomain*, size_t*);
static Il2CppImage* (*p_assembly_get_image)(const Il2CppAssembly*);
static size_t (*p_image_get_class_count)(const Il2CppImage*);
static Il2CppClass* (*p_image_get_class)(const Il2CppImage*, size_t);
static const char* (*p_class_get_name)(const Il2CppClass*);
static Il2CppFieldInfo* (*p_class_get_field_from_name)(const Il2CppClass*, const char*);
static void (*p_field_static_get_value)(Il2CppFieldInfo*, void*);

static bool g_il2cpp_ready = false;
static Il2CppClass* g_bm_class = NULL;
static Il2CppClass* g_gm_class = NULL;

static bool init_il2cpp(void) {
    p_domain_get              = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    p_domain_get_assemblies   = dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    p_assembly_get_image      = dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    p_image_get_class_count   = dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    p_image_get_class         = dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    p_class_get_name          = dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    p_class_get_field_from_name = dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
    p_field_static_get_value  = dlsym(RTLD_DEFAULT, "il2cpp_field_static_get_value");
    if (!p_domain_get || !p_domain_get_assemblies || !p_assembly_get_image ||
        !p_image_get_class_count || !p_image_get_class || !p_class_get_name ||
        !p_class_get_field_from_name || !p_field_static_get_value) return false;
    return true;
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

// ---- ESP settings (controlled by GUI) ----
static volatile bool g_esp_enabled = true;
static volatile bool g_show_names = true;
static volatile bool g_show_hp = true;
static volatile bool g_show_dead = false;

static int32_t read_i32(uintptr_t a) { int32_t v=0; if(a) memcpy(&v,(void*)a,4); return v; }
static bool read_bool(uintptr_t a) { uint8_t v=0; if(a) memcpy(&v,(void*)a,1); return v!=0; }
static uintptr_t read_ptr(uintptr_t a) { uintptr_t v=0; if(a) memcpy(&v,(void*)a,sizeof(v)); return v; }

static vec3 read_vec3(uintptr_t a) {
    vec3 v = {0};
    if (a) memcpy(&v, (void*)a, sizeof(v));
    return v;
}

static void read_string(uintptr_t str_ptr, char* out, int max_len) {
    out[0] = '\0';
    if (!str_ptr) return;
    int32_t len = read_i32(str_ptr + O_STRING_LENGTH);
    if (len <= 0 || len > 256) return;
    int rl = (len < max_len - 1) ? len : (max_len - 1);
    uint16_t chars[256];
    memcpy(chars, (void*)(str_ptr + O_STRING_CHARS), rl * sizeof(uint16_t));
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

// ---- class resolution ----
static Il2CppClass* find_class_by_name(const char* target) {
    if (!g_il2cpp_ready) return NULL;
    Il2CppDomain* domain = p_domain_get();
    if (!domain) return NULL;
    size_t asm_count = 0;
    const Il2CppAssembly** assemblies = p_domain_get_assemblies(domain, &asm_count);
    if (!assemblies) return NULL;
    for (size_t a = 0; a < asm_count; a++) {
        Il2CppImage* image = p_assembly_get_image(assemblies[a]);
        if (!image) continue;
        size_t cc = p_image_get_class_count(image);
        for (size_t c = 0; c < cc; c++) {
            Il2CppClass* klass = p_image_get_class(image, c);
            if (!klass) continue;
            const char* name = p_class_get_name(klass);
            if (name && strcmp(name, target) == 0) return klass;
        }
    }
    return NULL;
}

static bool resolve_classes(void) {
    if (!g_bm_class) g_bm_class = find_class_by_name("BattleManager");
    if (!g_gm_class) g_gm_class = find_class_by_name("GameMethod");
    return (g_bm_class != NULL);
}

static uintptr_t get_bm_instance(void) {
    if (!g_bm_class) return 0;
    Il2CppFieldInfo* f = p_class_get_field_from_name(g_bm_class, "Instance");
    if (!f) return 0;
    void* v = NULL;
    p_field_static_get_value(f, &v);
    return (uintptr_t)v;
}

static uintptr_t get_gm_mainCamera(void) {
    if (!g_gm_class) return 0;
    Il2CppFieldInfo* f = p_class_get_field_from_name(g_gm_class, "mainCamera");
    if (!f) return 0;
    void* v = NULL;
    p_field_static_get_value(f, &v);
    return (uintptr_t)v;
}

// ---- projection ----
static bool project_to_screen(vec3 world, float* sx, float* sy) {
    if (!g_cam_pos.x && !g_cam_pos.y && !g_cam_pos.z) return false;
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

    if (!g_il2cpp_ready || !g_bm_class) return;
    if (!g_esp_enabled) return; // skip reading entirely when ESP off

    uintptr_t bm = get_bm_instance();
    if (!bm) return;

    uintptr_t sf = get_gm_mainCamera();
    if (sf) g_cam_pos = read_vec3(sf + SF_m_CameraCurrentPos);

    uintptr_t list = read_ptr(bm + BM_m_ShowPlayers);
    if (!list) return;
    uintptr_t arr = read_ptr(list + O_LIST_ITEMS);
    if (!arr) return;
    int32_t count = read_i32(arr + O_ARRAY_LENGTH);
    if (count <= 0) return;
    if (count > MAX_ENTITIES) count = MAX_ENTITIES;

    uintptr_t ents[MAX_ENTITIES];
    memcpy(ents, (void*)(arr + O_ARRAY_DATA), count * sizeof(uintptr_t));

    ESPEntityData local[MAX_ENTITIES];
    int n = 0;
    for (int i = 0; i < count && n < MAX_ENTITIES; i++) {
        uintptr_t ep = ents[i];
        if (!ep) continue;
        ESPEntityData* e = &local[n];
        memset(e, 0, sizeof(ESPEntityData));

        e->is_dead = read_bool(ep + SE_m_bDeath);
        e->camp    = read_i32(ep + SE_m_EntityCampType);
        e->hp      = read_i32(ep + SE_m_Hp);
        e->hpmax   = read_i32(ep + SE_m_HpMax);
        e->level   = read_i32(ep + SE_m_Level);
        e->is_self = read_bool(ep + SE_m_bSelf);

        read_string(read_ptr(ep + SE_m_RoleName),  e->name, sizeof(e->name));
        read_string(read_ptr(ep + SP_m_HeroName),  e->hero, sizeof(e->hero));

        vec3 world = read_vec3(ep + SE_m_vUnityCachePos);
        if (!world.x && !world.y && !world.z) continue;

        float fx, fy, hx, hy;
        vec3 feet = world;
        vec3 head = { world.x, world.y + HERO_HEIGHT, world.z };
        if (!project_to_screen(feet, &fx, &fy)) continue;
        if (!project_to_screen(head, &hx, &hy)) continue;

        float bh = fabsf(fy - hy);
        if (bh < 4.0f) bh = 4.0f;
        float bw = bh * 0.55f;
        e->sx = hx - bw / 2.0f;
        e->sy = hy;
        e->bw = bw;
        e->bh = bh;
        e->is_visible = (e->sx >= 0 && e->sx <= g_screen_w &&
                         e->sy >= 0 && e->sy <= g_screen_h);
        n++;
    }

    pthread_mutex_lock(&g_lock);
    memcpy(g_entities, local, n * sizeof(ESPEntityData));
    g_entity_count = n;
    pthread_mutex_unlock(&g_lock);
}

static void* reader_thread(void* arg) {
    (void)arg;
    int attempts = 0;
    while (!g_il2cpp_ready && attempts < 120) {
        if (init_il2cpp()) { g_il2cpp_ready = true; break; }
        attempts++;
        usleep(1000000);
    }
    if (!g_il2cpp_ready) return NULL;
    NSLog(@"[MLBBESP] IL2CPP API ready");

    attempts = 0;
    while (!resolve_classes() && attempts < 180) {
        attempts++;
        usleep(2000000);
    }
    if (!g_bm_class) { NSLog(@"[MLBBESP] BattleManager not found"); return NULL; }
    NSLog(@"[MLBBESP] Classes resolved");

    while (true) {
        @autoreleasepool { read_all_entities(); }
        usleep(33333);
    }
    return NULL;
}

// ===========================================================================
// ESP OVERLAY VIEW (draws boxes)
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

- (void)tick:(CADisplayLink*)l { [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
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
        if (!e->is_visible || e->is_self) continue;
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
            NSString* label = [NSString stringWithFormat:@"%s [%d]", e->hero, e->level];
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
@property (strong, nonatomic) UISwitch* espSwitch;
@property (strong, nonatomic) UISwitch* namesSwitch;
@property (strong, nonatomic) UISwitch* hpSwitch;
@property (strong, nonatomic) UISwitch* deadSwitch;
@property (strong, nonatomic) UILabel* titleLabel;
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

        // Title
        self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 24)];
        self.titleLabel.text = @"MLBB ESP";
        self.titleLabel.textColor = [UIColor whiteColor];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [self addSubview:self.titleLabel];

        // ESP toggle
        UILabel* espLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 50, 150, 20)];
        espLabel.text = @"ESP Enabled";
        espLabel.textColor = [UIColor lightGrayColor];
        espLabel.font = [UIFont systemFontOfSize:13];
        [self addSubview:espLabel];

        self.espSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(self.frame.size.width - 70, 46, 0, 0)];
        self.espSwitch.on = g_esp_enabled;
        self.espSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [self.espSwitch addTarget:self action:@selector(espToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.espSwitch];

        // Names toggle
        UILabel* namesLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 92, 150, 20)];
        namesLabel.text = @"Show Names";
        namesLabel.textColor = [UIColor lightGrayColor];
        namesLabel.font = [UIFont systemFontOfSize:13];
        [self addSubview:namesLabel];

        self.namesSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(self.frame.size.width - 70, 88, 0, 0)];
        self.namesSwitch.on = g_show_names;
        self.namesSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [self.namesSwitch addTarget:self action:@selector(namesToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.namesSwitch];

        // HP toggle
        UILabel* hpLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 134, 150, 20)];
        hpLabel.text = @"Show HP Bar";
        hpLabel.textColor = [UIColor lightGrayColor];
        hpLabel.font = [UIFont systemFontOfSize:13];
        [self addSubview:hpLabel];

        self.hpSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(self.frame.size.width - 70, 130, 0, 0)];
        self.hpSwitch.on = g_show_hp;
        self.hpSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [self.hpSwitch addTarget:self action:@selector(hpToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.hpSwitch];

        // Dead toggle
        UILabel* deadLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 176, 150, 20)];
        deadLabel.text = @"Show Dead";
        deadLabel.textColor = [UIColor lightGrayColor];
        deadLabel.font = [UIFont systemFontOfSize:13];
        [self addSubview:deadLabel];

        self.deadSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(self.frame.size.width - 70, 172, 0, 0)];
        self.deadSwitch.on = g_show_dead;
        self.deadSwitch.onTintColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:1];
        [self.deadSwitch addTarget:self action:@selector(deadToggled:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:self.deadSwitch];

        // Close button
        UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(16, 214, self.frame.size.width - 32, 36);
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

- (void)closeTapped {
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1;
    }];
}

@end

// ===========================================================================
// FLOATING BUTTON (draggable toggle)
// ===========================================================================

@interface FloatingButton : UIButton
@property (strong, nonatomic) UIPanGestureRecognizer* pan;
@property (assign, nonatomic) CGPoint originalCenter;
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
    CGPoint translation = [gr translationInView:self.superview];
    if (gr.state == UIGestureRecognizerStateBegan) {
        self.originalCenter = self.center;
        self.moved = false;
    }
    if (gr.state == UIGestureRecognizerStateChanged) {
        if (fabs(translation.x) > 4 || fabs(translation.y) > 4) self.moved = true;
        CGPoint newCenter = CGPointMake(self.originalCenter.x + translation.x,
                                        self.originalCenter.y + translation.y);
        // Clamp to screen
        CGFloat half = self.frame.size.width / 2.0;
        newCenter.x = MAX(half, MIN(self.superview.frame.size.width - half, newCenter.x));
        newCenter.y = MAX(half, MIN(self.superview.frame.size.height - half, newCenter.y));
        self.center = newCenter;
    }
    if (gr.state == UIGestureRecognizerStateEnded) {
        // Snap to nearest edge
        CGFloat half = self.frame.size.width / 2.0;
        CGFloat centerX = self.center.x;
        CGFloat targetX;
        if (centerX < self.superview.frame.size.width / 2.0) {
            targetX = half + 8;
        } else {
            targetX = self.superview.frame.size.width - half - 8;
        }
        [UIView animateWithDuration:0.2 animations:^{
            self.center = CGPointMake(targetX, self.center.y);
        }];
    }
}

- (void)tapped {
    if (self.moved) return; // was a drag, not a tap
    [ESPMenuController.shared togglePanel];
}

@end

// ===========================================================================
// MENU CONTROLLER
// ===========================================================================

@interface ESPMenuController : NSObject
+ (instancetype)shared;
- (void)togglePanel;
- (void)showPanel;
- (void)hidePanel;
@property (strong, nonatomic) UIWindow* controlWindow;
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
    if (self.controlWindow) return;

    CGRect b = UIScreen.mainScreen.bounds;

    // Control window (interactive)
    self.controlWindow = [[UIWindow alloc] initWithFrame:b];
    if (@available(iOS 13.0, *)) self.controlWindow.windowScene = keyWindow.windowScene;
    self.controlWindow.windowLevel = UIWindowLevelAlert + 1000;
    self.controlWindow.backgroundColor = [UIColor clearColor];
    self.controlWindow.userInteractionEnabled = YES;
    self.controlWindow.hidden = NO;

    // Floating button
    CGFloat btnSize = 52;
    self.floatingBtn = [[FloatingButton alloc] initWithFrame:CGRectMake(b.size.width - btnSize - 12, b.size.height * 0.25, btnSize, btnSize)];
    [self.controlWindow addSubview:self.floatingBtn];

    // Settings panel (hidden initially)
    CGFloat panelW = 260;
    CGFloat panelH = 264;
    CGFloat panelX = (b.size.width - panelW) / 2.0;
    CGFloat panelY = (b.size.height - panelH) / 2.0;
    self.panel = [[SettingsPanel alloc] initWithFrame:CGRectMake(panelX, panelY, panelW, panelH)];
    self.panel.hidden = YES;
    self.panel.alpha = 0;
    [self.controlWindow addSubview:self.panel];

    self.panelVisible = false;
    NSLog(@"[MLBBESP] Control window ready");
}

- (void)togglePanel {
    if (self.panelVisible) [self hidePanel];
    else [self showPanel];
}

- (void)showPanel {
    if (!self.panel) return;
    self.panel.hidden = NO;
    self.panel.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.2 animations:^{
        self.panel.alpha = 1;
        self.panel.transform = CGAffineTransformIdentity;
    }];
    self.panelVisible = true;
}

- (void)hidePanel {
    if (!self.panel) return;
    [UIView animateWithDuration:0.2 animations:^{
        self.panel.alpha = 0;
        self.panel.transform = CGAffineTransformMakeScale(0.9, 0.9);
    } completion:^(BOOL finished) {
        self.panel.hidden = YES;
        self.panel.transform = CGAffineTransformIdentity;
        self.panel.alpha = 1;
    }];
    self.panelVisible = false;
}

@end

// ===========================================================================
// ESP OVERLAY WINDOW (draw-only, no interaction)
// ===========================================================================

static UIWindow* g_overlay_window = nil;
static ESPOverlayView* g_overlay_view = nil;

static void create_overlay(UIWindow* key) {
    if (g_overlay_window) return;

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

static void poll_windows(void) {
    static int polls = 0;
    if (g_overlay_window) return;
    if (polls > 120) return;
    polls++;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow* key = nil;
        for (UIWindow* w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (!key) {
            poll_windows();
            return;
        }

        create_overlay(key);
        [[ESPMenuController shared] setupWithKeyWindow:key];
        [key makeKeyWindow]; // give focus back to game
    });
}

// ===========================================================================
// CONSTRUCTOR
// ===========================================================================

__attribute__((constructor))
static void MLBBESP_init(void) {
    NSLog(@"[MLBBESP] Loaded");
    pthread_t t;
    pthread_create(&t, NULL, reader_thread_ref(), NULL);
    pthread_detach(t);
    dispatch_async(dispatch_get_main_queue(), ^{ poll_windows(); });
}

// forward declaration fix
static void* reader_thread_ref(void) {
    return (void*)reader_thread;
}