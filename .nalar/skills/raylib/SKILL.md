---
name: raylib
description: Use raylib when users mention game development, 2D/3D graphics, game prototyping, videogame programming, or any C-based game library. Apply when users want to create games, graphical applications, interactive visualizations, or need help with raylib API. Trigger on: "make a game", "2D graphics", "3D rendering", "game loop", "raylib", "DrawText", "initWindow", "beginDrawing", or any game programming request. Also triggers for raylib bindings in other languages (raylib-zig, pyraylib, raylib-rs, etc.).
version: 1.0.0
compatibility: ["zig", "c", "c++", "python", "rust"]
---

# Raylib Skill

Create games, graphical applications, and interactive experiences with raylib — a simple, easy-to-use C library for game programming.

## Quick Start Template

```c
#include "raylib.h"

int main(void) {
    // Initialization
    const int screenWidth = 800;
    const int screenHeight = 450;
    InitWindow(screenWidth, screenHeight, "My Game");
    
    // Game state variables here
    
    SetTargetFPS(60);  // Optional: lock framerate
    
    // Main game loop
    while (!WindowShouldClose()) {
        // Update
        // (handle input, update physics, game logic)
        
        // Draw
        BeginDrawing();
            ClearBackground(RAYWHITE);
            DrawText("Congrats! You created your first window!", 190, 200, 20, DARKGRAY);
            // ... more drawing code ...
        EndDrawing();
    }
    
    // Cleanup
    CloseWindow();
    return 0;
}
```

## Core Concepts

### 1. Window Management

| Function | Purpose |
|----------|---------|
| `InitWindow(width, height, title)` | Create window and initialize OpenGL |
| `CloseWindow()` | Close window and unload OpenGL context |
| `WindowShouldClose()` | Check if window close flag or ESC key pressed |
| `IsWindowReady()` | Check if window has been initialized |
| `SetWindowState(flags)` | Set window configuration flags |
| `ToggleFullscreen()` | Toggle window fullscreen state |

### 2. Rendering Loop

The fundamental pattern is always:
```c
while (!WindowShouldClose()) {
    // 1. Update game state
    UpdateGame();  // Your function
    
    // 2. Render
    BeginDrawing();
        ClearBackground((Color){ 245, 245, 245, 255 });  // Light gray
        DrawGame();
    EndDrawing();
}
```

### 3. 2D Drawing Primitives

```c
// Colors - use predefined colors or create custom
Color RED = { 255, 0, 0, 255 };
Color myColor = (Color){ r, g, b, a };  // 0-255 values

// Basic shapes
DrawPixel(x, y, color);
DrawLine(startX, startY, endX, endY, color);
DrawCircle(centerX, centerY, radius, color);
DrawCircleLines(centerX, centerY, radius, color);
DrawRectangle(posX, posY, width, height, color);
DrawRectangleLines(posX, posY, width, height, lineThick, color);
DrawTriangle(Vector2 p1, p2, p3, color);
DrawText(text, posX, posY, fontSize, color);

// With rotation and origin
DrawRectanglePro(Rectangle rec, Vector2 origin, float rotation, color);
DrawCircleSector(Vector2 center, float radius, int startAngle, int endAngle, int segments, color);
```

### 4. Text and Fonts

```c
// Load font (TTF, OTF, etc.)
Font myFont = LoadFont("resources/custom_font.ttf");

// Draw with default font
DrawText("Hello World", x, y, fontSize, color);

// Draw with custom font
DrawTextEx(myFont, "Custom Font Text", (Vector2){x, y}, fontSize, spacing, color);

// Text utilities
MeasureText(text, fontSize);  // Get text width in pixels
TextFormat("Score: %d", score);  // Format text like sprintf
```

### 5. Textures and Images

```c
// Load texture (PNG, JPG, BMP, TGA, etc.)
Texture2D myTexture = LoadTexture("resources/sprite.png");

// Draw texture
DrawTexture(myTexture, x, y, WHITE);  // WHITE = no tint
DrawTextureEx(myTexture, (Vector2){x, y}, rotation, scale, tint);
DrawTexturePro(myTexture, sourceRec, destRec, origin, rotation, tint);

// Unload when done
UnloadTexture(myTexture);

// Image manipulation
Image image = LoadImage("photo.png");
ImageResize(&image, newWidth, newHeight);
ImageFlipHorizontal(&image);
ExportImage(image, "output.png");
UnloadImage(image);
```

### 6. Input Handling

```c
// Keyboard
if (IsKeyDown(KEY_W) || IsKeyDown(KEY_UP)) { /* move up */ }
if (IsKeyPressed(KEY_SPACE)) { /* jump - triggers once */ }
int key = GetKeyPressed();  // Get last key pressed (non-blocking)
if (IsKeyReleased(KEY_ENTER)) { /* handle key release */ }

// Mouse
Vector2 mousePos = GetMousePosition();
if (IsMouseButtonDown(MOUSE_LEFT_BUTTON)) { /* dragging */ }
if (IsMouseButtonPressed(MOUSE_RIGHT_BUTTON)) { /* right click */ }
float wheel = GetMouseWheelMove();  // Scroll wheel

// Gamepad
bool gamepadReady = IsGamepadAvailable(0);
float leftX = GetGamepadAxisMovement(0, GAMEPAD_AXIS_LEFT_X);
if (IsGamepadButtonPressed(0, GAMEPAD_BUTTON_A)) { /* A button */ }

// Touch (mobile)
Vector2 touch = GetTouchPosition(0);
```

### 7. Audio

```c
// Initialize audio device
InitAudioDevice();

// Load sound (WAV, MP3, OGG, FLAC)
Sound mySound = LoadSound("jump.wav");
Sound music = LoadSound("music.mp3");

// Play sounds
PlaySound(mySound);
PlaySound(music);

// Control playback
SetSoundVolume(mySound, 0.5f);  // 0.0 to 1.0
SetSoundPitch(mySound, 1.2f);   // Speed/pitch multiplier
PauseSound(mySound);
ResumeSound(mySound);
StopSound(mySound);

// Unload
UnloadSound(mySound);
UnloadSound(music);

// Close audio when done
CloseAudioDevice();
```

### 8. 3D Rendering

```c
// Camera setup
Camera3D camera = { 0 };
camera.position = (Vector3){ 0, 10, 10 };
camera.target = (Vector3){ 0, 0, 0 };
camera.up = (Vector3){ 0, 1, 0 };
camera.fovy = 45.0f;
camera.projection = CAMERA_PERSPECTIVE;

// 3D mode
BeginMode3D(camera);
    // Draw 3D objects
    DrawCube((Vector3){0, 2, 0}, 2, 2, 2, RED);
    DrawCubeWires((Vector3){0, 2, 0}, 2, 2, 2, MAROON);
    DrawPlane((Vector3){0, 0, 0}, (Vector2){32, 32}, BEIGE);
    DrawGrid(20, 1.0f);
    
    // Draw models
    Model model = LoadModel("robot.glb");
    DrawModel(model, (Vector3){0, 0, 0}, 1.0f, WHITE);
    UnloadModel(model);
EndMode3D();

// Camera controls (built-in)
UpdateCamera(&camera, CAMERA_ORBITAL);  // Mouse drag to orbit
// Also: CAMERA_FIRST_PERSON, CAMERA_THIRD_PERSON
```

### 9. Collision Detection

```c
#include "raymath.h"

// Rectangle collision
bool CheckCollisionRecs(Rectangle r1, Rectangle r2);

// Circle collision
bool CheckCollisionCircles(Vector2 center1, float r1, Vector2 center2, float r2);

// Circle vs Rectangle
bool CheckCollisionCircleRec(Vector2 center, float radius, Rectangle rec);

// Point in rectangle
bool CheckCollisionPointRec(Vector2 point, Rectangle rec);

// Get collision rectangle (for resolution)
Rectangle GetCollisionRec(Rectangle r1, Rectangle r2);
```

### 10. Timing

```c
// Get time
float time = GetTime();  // Seconds since InitWindow
double frameTime = GetFrameTime();  // Delta time in seconds
int fps = GetFPS();

// Set target framerate
SetTargetFPS(60);

// Wait for frame duration
WaitTime(0.1f);  // Wait 100ms
```

## Common Patterns

### Pattern 1: Simple 2D Game

```c
typedef struct {
    Vector2 position;
    Vector2 velocity;
    Color color;
} Ball;

int main(void) {
    InitWindow(800, 600, "Bouncing Ball");
    Ball ball = { {400, 300}, {5, 4}, RED };
    
    while (!WindowShouldClose()) {
        // Update
        ball.position.x += ball.velocity.x;
        ball.position.y += ball.velocity.y;
        
        // Bounce off walls
        if (ball.position.x < 0 || ball.position.x > 800) ball.velocity.x *= -1;
        if (ball.position.y < 0 || ball.position.y > 600) ball.velocity.y *= -1;
        
        // Draw
        BeginDrawing();
        ClearBackground(BLACK);
        DrawCircleV(ball.position, 20, ball.color);
        DrawFPS(10, 10);
        EndDrawing();
    }
    
    CloseWindow();
    return 0;
}
```

### Pattern 2: Sprite Animation

```c
typedef struct {
    Texture2D texture;
    int numFrames;
    int currentFrame;
    float frameWidth;
    float animTimer;
    float animSpeed;
} SpriteAnimator;

void UpdateSprite(SpriteAnimator *anim, float dt) {
    anim->animTimer += dt;
    if (anim->animTimer >= anim->animSpeed) {
        anim->animTimer = 0;
        anim->currentFrame = (anim->currentFrame + 1) % anim->numFrames;
    }
}

void DrawSprite(SpriteAnimator anim, Vector2 pos) {
    Rectangle source = { anim.currentFrame * anim.frameWidth, 0, anim.frameWidth, anim.texture.height };
    Rectangle dest = { pos.x, pos.y, anim.frameWidth, anim.texture.height };
    DrawTexturePro(anim.texture, source, dest, (Vector2){0, 0}, 0, WHITE);
}
```

### Pattern 3: Camera Follow

```c
void UpdateCameraFollow(Camera2D *cam, Vector2 target, float smoothness) {
    cam->target = Vector2Lerp(cam->target, target, smoothness);
    cam->offset = (Vector2){ screenWidth/2.0f, screenHeight/2.0f };
}

// Usage in game loop
Camera2D cam = { 0 };
Vector2 playerPos = { player.x, player.y };
UpdateCameraFollow(&cam, playerPos, 0.1f);

BeginMode2D(cam);
    // Draw world (player, enemies, map, etc.)
EndMode2D();
```

### Pattern 4: Screen Shake

```c
typedef struct {
    Vector2 offset;
    float intensity;
    float duration;
    float timer;
} ScreenShake;

void UpdateShake(ScreenShake *shake, float dt) {
    if (shake->timer > 0) {
        shake->timer -= dt;
        shake->offset.x = (GetRandomValue(-100, 100) / 100.0f) * shake->intensity;
        shake->offset.y = (GetRandomValue(-100, 100) / 100.0f) * shake->intensity;
    } else {
        shake->offset = (Vector2){ 0, 0 };
    }
}

void TriggerShake(ScreenShake *shake, float intensity, float duration) {
    shake->intensity = intensity;
    shake->duration = duration;
    shake->timer = duration;
}
```

## Building Projects

### C/C++ with Make

```makefile
# Makefile
PROJECT_NAME = mygame
RAYLIB_PATH = /usr/local

# Unix default paths
ifeq ($(PLATFORM),PLATFORM_WINDOWS)
    RAYLIB_PATH = C:/raylib/raylib
endif

CC = gcc
CFLAGS = -Wall -Wextra -std=c99 -pedantic
LDFLAGS = -L$(RAYLIB_PATH)/lib -lraylib -lGL -lm -lpthread -ldl

all:
	$(CC) $(PROJECT_NAME).c -o $(PROJECT_NAME) $(LDFLAGS)
```

### CMake

```cmake
cmake_minimum_required(VERSION 3.0)
project(mygame C)

add_executable(${PROJECT_NAME} main.c)

# Find raylib (pkg-config on Linux, or manual)
find_package(raylib REQUIRED)

# Link libraries
target_link_libraries(${PROJECT_NAME} raylib opengl pthread)
```

### Zig Build

```zig
const raylib = @import("raylib");

pub fn main() void {
    raylib.InitWindow(800, 450, "My Game");
    defer raylib.CloseWindow();
    
    while (!raylib.WindowShouldClose()) {
        raylib.BeginDrawing();
        defer raylib.EndDrawing();
        
        raylib.ClearBackground(raylib.RAYWHITE);
        raylib.DrawText("Hello from Zig!", 190, 200, 20, raylib.DARKGRAY);
    }
}
```

## Tips for Better Games

1. **Use delta time** for frame-rate independent movement:
   ```c
   float speed = 200.0f;  // pixels per second
   float delta = GetFrameTime();
   player.x += speed * delta * (IsKeyDown(KEY_RIGHT) ? 1 : -1);
   ```

2. **Batch similar draw calls** for better performance:
   - Group all rectangles together, then all circles, etc.
   - Use `DrawTexturePro` with texture atlases

3. **Use camera for scrolling games** instead of offsetting all coordinates manually

4. **Preload assets** during a loading screen, not in the game loop

5. **Handle window resize** for responsive games:
   ```c
   if (IsWindowResized()) {
       screenWidth = GetScreenWidth();
       screenHeight = GetScreenHeight();
   }
   ```

6. **Use structs to organize game objects** — don't use global variables

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Undefined reference to InitWindow" | Link with `-lraylib` or install raylib development package |
| Black screen on start | Ensure `BeginDrawing()`/`EndDrawing()` wrap all draw calls |
| No audio | Call `InitAudioDevice()` before loading sounds |
| Textures look blurry | Use `SetTextureFilter()` with `TEXTURE_FILTER_POINT` |
| Slow performance | Use texture atlases, batch draw calls, reduce texture sizes |
| Crash on texture unload | Make sure no drawing uses the texture before `UnloadTexture()` |

## Color Palette (Predefined Colors)

```
RAYWHITE  = { 248, 248, 255, 255 }
LIGHTGRAY = { 196, 196, 198, 255 }
GRAY      = { 130, 130, 130, 255 }
DARKGRAY  = { 80, 80, 80, 255 }
BLACK     = { 0, 0, 0, 255 }
WHITE     = { 255, 255, 255, 255 }
RED       = { 230, 41, 55, 255 }
MAROON    = { 190, 33, 55, 255 }
ORANGE    = { 255, 159, 47, 255 }
GOLD      = { 255, 201, 14, 255 }
YELLOW    = { 253, 249, 0, 255 }
GREEN     = { 0, 228, 48, 255 }
LIME      = { 0, 158, 47, 255 }
DARKGREEN = { 0, 117, 44, 255 }
SKYBLUE   = { 102, 191, 255, 255 }
BLUE      = { 0, 121, 241, 255 }
DARKBLUE  = { 0, 82, 172, 255 }
PURPLE    = { 200, 70, 255, 255 }
VIOLET    = { 135, 60, 190, 255 }
DARKPURPLE= { 112, 31, 126, 255 }
PINK      = { 255, 109, 194, 255 }
BEIGE     = { 245, 245, 220, 255 }
BROWN     = { 127, 106, 79, 255 }
DARKBROWN = { 76, 63, 47, 255 }
MAGENTA   = { 255, 0, 255, 255 }
```

## Resources

- **Website**: https://www.raylib.com
- **Cheatsheet**: https://www.raylib.com/cheatsheet/cheatsheet.html
- **Examples**: https://www.raylib.com/examples.html
- **GitHub**: https://github.com/raysan5/raylib
- **Discord**: https://discord.gg/raylib
- **Zig binding**: https://github.com/Sobeston/raylib-zig
- **Python binding**: https://github.com/joesteven/raylib-python-cffi
