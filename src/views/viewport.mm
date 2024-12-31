#include "viewport.h"

#include <pxr/base/gf/camera.h>
#include <pxr/base/gf/frustum.h>
#include <pxr/base/gf/matrix4f.h>
#include <pxr/base/plug/plugin.h>
#include <pxr/imaging/cameraUtil/framing.h>
#include <pxr/imaging/hd/cameraSchema.h>
#include <pxr/imaging/hd/extentSchema.h>
#include <pxr/usd/usd/stage.h>
#include <pxr/imaging/hgi/blitCmdsOps.h>
#include <pxr/imaging/hgiMetal/hgi.h>
#include <pxr/imaging/hgiMetal/texture.h>
#include <pxr/imaging/hdSt/renderBuffer.h>

#import <Metal/Metal.h>

extern "C"
int LabCreateRGBAf16Texture(int width, int height, uint8_t* rgba_pixels);
extern "C"
void* LabTextureHardwareHandle(int texture);
extern "C"
void LabRemoveTexture(int texture);
extern "C"
void LabUpdateRGBAf16Texture(int texture, uint8_t* rgba_pixels);


struct TextureCapture {
    int width = 0;
    int height = 0;
    int handle = -1;
};

TextureCapture texcap;

PXR_NAMESPACE_OPEN_SCOPE

Viewport::Viewport(Model* model, const string label) : View(model, label)
{
    _gizmoWindowFlags = ImGuiWindowFlags_MenuBar;
    _isAmbientLightEnabled = true;
    _isDomeLightEnabled = false;
    _isGridEnabled = true;

    _curOperation = ImGuizmo::TRANSLATE;
    _curMode = ImGuizmo::LOCAL;

    _eye = GfVec3d(5, 5, 5);
    _at = GfVec3d(0, 0, 0);
    _up = GfVec3d::YAxis();

    _UpdateActiveCamFromViewport();

    _gridSceneIndex = GridSceneIndex::New();
    GetModel()->AddSceneIndexBase(_gridSceneIndex);

    auto editableSceneIndex = GetModel()->GetEditableSceneIndex();
    _xformSceneIndex = XformFilterSceneIndex::New(editableSceneIndex);
    GetModel()->SetEditableSceneIndex(_xformSceneIndex);

    TfToken plugin = Engine::GetDefaultRendererPlugin();
    _engine = new Engine(GetModel()->GetFinalSceneIndex(), plugin);
};

Viewport::~Viewport()
{
    delete _engine;
}

const string Viewport::GetViewType()
{
    return VIEW_TYPE;
};

ImGuiWindowFlags Viewport::_GetGizmoWindowFlags()
{
    return _gizmoWindowFlags;
};

float Viewport::_GetViewportWidth()
{
    return GetInnerRect().GetWidth();
}

float Viewport::_GetViewportHeight()
{
    return GetInnerRect().GetHeight();
}

void Viewport::_Draw()
{
    _DrawMenuBar();

    if (_GetViewportWidth() <= 0 || _GetViewportHeight() <= 0) return;

    ImGui::BeginChild("GameRender");

    _ConfigureImGuizmo();

    // read from active cam in case it is modify by another view
    if (!ImGui::IsWindowFocused()) _UpdateViewportFromActiveCam();

    _UpdateProjection();
    _UpdateGrid();
    _UpdateHydraRender();
    _UpdateTransformGuizmo();
    _UpdateCubeGuizmo();
    _UpdatePluginLabel();

    ImGui::EndChild();
};

void Viewport::_DrawMenuBar()
{
    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu("transform")) {
            if (ImGui::MenuItem("local translate")) {
                _curOperation = ImGuizmo::TRANSLATE;
                _curMode = ImGuizmo::LOCAL;
            }
            if (ImGui::MenuItem("local rotation")) {
                _curOperation = ImGuizmo::ROTATE;
                _curMode = ImGuizmo::LOCAL;
            }
            if (ImGui::MenuItem("local scale")) {
                _curOperation = ImGuizmo::SCALE;
                _curMode = ImGuizmo::LOCAL;
            }
            if (ImGui::MenuItem("global translate")) {
                _curOperation = ImGuizmo::TRANSLATE;
                _curMode = ImGuizmo::WORLD;
            }
            if (ImGui::MenuItem("global rotation")) {
                _curOperation = ImGuizmo::ROTATE;
                _curMode = ImGuizmo::WORLD;
            }
            if (ImGui::MenuItem("global scale")) {
                _curOperation = ImGuizmo::SCALE;
                _curMode = ImGuizmo::WORLD;
            }

            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("renderer")) {
            // get all possible renderer plugins
            TfTokenVector plugins = _engine->GetRendererPlugins();
            TfToken curPlugin = _engine->GetCurrentRendererPlugin();
            for (auto p : plugins) {
                bool enabled = (p == curPlugin);
                string name = _engine->GetRendererPluginName(p);
                if (ImGui::MenuItem(name.c_str(), NULL, enabled)) {
                    delete _engine;
                    _engine = new Engine(GetModel()->GetFinalSceneIndex(), p);
                }
            }
            ImGui::EndMenu();
        }

        if (ImGui::BeginMenu("cameras")) {
            bool enabled = (_activeCam.IsEmpty());
            if (ImGui::MenuItem("free camera", NULL, &enabled)) {
                _SetFreeCamAsActive();
            }
            for (SdfPath path : GetModel()->GetCameras()) {
                bool enabled = (path == _activeCam);
                if (ImGui::MenuItem(path.GetName().c_str(), NULL, enabled)) {
                    _SetActiveCam(path);
                }
            }
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("lights")) {
            ImGui::MenuItem("ambient light", NULL, &_isAmbientLightEnabled);
            ImGui::MenuItem("dome light", NULL, &_isDomeLightEnabled);
            ImGui::EndMenu();
        }
        if (ImGui::BeginMenu("show")) {
            ImGui::MenuItem("grid", NULL, &_isGridEnabled);
            ImGui::EndMenu();
        }
        ImGui::EndMenuBar();
    }
}

void Viewport::_ConfigureImGuizmo()
{
    ImGuizmo::BeginFrame();

    // convert last label char to ID
    string label = GetViewLabel();
    ImGuizmo::SetID(int(label[label.size() - 1]));

    ImGuizmo::SetDrawlist();
    ImGuizmo::SetRect(GetInnerRect().Min.x, GetInnerRect().Min.y,
                      _GetViewportWidth(), _GetViewportHeight());
}

void Viewport::_UpdateGrid()
{
    _gridSceneIndex->Populate(_isGridEnabled);

    if (!_isGridEnabled) return;

    GfMatrix4f viewF(_getCurViewMatrix());
    GfMatrix4f projF(_proj);
    GfMatrix4f identity(1);

    ImGuizmo::DrawGrid(viewF.data(), projF.data(), identity.data(), 10);
}

static uint8_t*
GetGPUTexture(
    HgiMetal& hgiMetal,
    HgiTextureHandle const& texHandle,
    int width,
    int height,
    HgiFormat format)
{
    // Copy the pixels from gpu into a cpu buffer so we can save it to disk.
    const size_t bufferByteSize =
        width * height * HgiGetDataSizeOfFormat(format);
    static uint8_t* buffer = nullptr;
    static size_t sz = 0;
    if (sz < bufferByteSize) {
        if (buffer) {
            free(buffer);
            buffer = nullptr;
        }
        sz = 0;
    }
    if (!buffer) {
        buffer = (uint8_t*) malloc(bufferByteSize);
        sz = bufferByteSize;
    }

    HgiTextureGpuToCpuOp copyOp;
    copyOp.gpuSourceTexture = texHandle;
    copyOp.sourceTexelOffset = GfVec3i(0);
    copyOp.mipLevel = 0;
    copyOp.cpuDestinationBuffer = buffer;
    copyOp.destinationByteOffset = 0;
    copyOp.destinationBufferByteSize = bufferByteSize;

    HgiBlitCmdsUniquePtr blitCmds = hgiMetal.CreateBlitCmds();
    blitCmds->CopyTextureGpuToCpu(copyOp);
    hgiMetal.SubmitCmds(blitCmds.get(), HgiSubmitWaitTypeWaitUntilCompleted);

    return buffer;
    //_SaveToPNG(width, height, buffer.data(), filePath);
}


void Viewport::_UpdateHydraRender()
{
    auto model = GetModel();
    if (!model)
        return;

    GfMatrix4d view = _getCurViewMatrix();
    float width = _GetViewportWidth();
    float height = _GetViewportHeight();

    // set selection
    SdfPathVector paths;
    for (auto&& prim : model->GetSelection())
        paths.push_back(prim.GetPrimPath());

    _engine->SetSelection(paths);
    _engine->SetRenderSize(width, height);
    _engine->SetCameraMatrices(view, _proj);
    _engine->Prepare();

    // do the render
    _engine->Render();

    auto tc = _engine->GetHdxTaskController();
    HdRenderBuffer* buffer = tc->GetRenderOutput(HdAovTokens->color);
    buffer->Resolve();
    VtValue aov = buffer->GetResource(false);
    if (aov.IsHolding<HgiTextureHandle>()) {
        HgiTextureHandle textureHandle = aov.Get<HgiTextureHandle>();
        HgiMetalTexture* hgiMetalTexture = static_cast<HgiMetalTexture*>(textureHandle.Get());
        if (hgiMetalTexture) {
            id<MTLTexture> tex = hgiMetalTexture->GetTextureId();
#if 1
            HgiFormat format = HgiFormatFloat16Vec4;
            switch(tex.pixelFormat) {
                case MTLPixelFormatDepth32Float:
                    format = HgiFormatFloat32; break;
                case MTLPixelFormatRGBA16Unorm:
                    format = HgiFormatUInt16Vec4; break;
                case MTLPixelFormatRGBA16Float:
                    format = HgiFormatFloat16Vec4; break;
                default: break;
            }

            Hgi* hgi = _engine->GetHgi();
            HgiMetal* hgiMetal = dynamic_cast<HgiMetal*>(hgi);
            if (hgi) {
                auto buffer = GetGPUTexture(*hgiMetal,
                                            textureHandle,
                                            width, height,
                                            format);

                if (texcap.width != width || texcap.height != height || texcap.handle < 0) {
                    if (texcap.handle > 0) {
                        LabRemoveTexture(texcap.handle);
                    }
                    texcap.width = width;
                    texcap.height = height;
                    texcap.handle = LabCreateRGBAf16Texture(width, height, buffer);
                }
                else {
                    LabUpdateRGBAf16Texture(texcap.handle, (uint8_t*) buffer);
                }

                ImGui::Image((ImTextureID) LabTextureHardwareHandle(texcap.handle),
                             ImVec2(width, height),
                             ImVec2(0, 1), ImVec2(1, 0));
            }

#elif 0
            // assume synchronized textures...
            /// @TODO Hydra doesn't sync.
            ImGui::Image((ImTextureID) tex,
                         ImVec2(width, height),
                         ImVec2(0, 1), ImVec2(1, 0));
#else
            // copy and cache the texture

            /// @TOOD wire these through from MetalProvider
            // Assume you have an MTLCommandQueue and MTLCommandBuffer created earlier
            auto device = MTLCreateSystemDefaultDevice();
            id<MTLCommandQueue> commandQueue = [device newCommandQueue];
            id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

            static id<MTLTexture> bufferedTexture = nil;
            if (bufferedTexture == nil) {
                MTLTextureDescriptor* desc = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                                             width:tex.width
                                                            height:tex.height
                                                         mipmapped:NO];
                bufferedTexture = [device newTextureWithDescriptor:desc];
            }
            // if the buffered texture size differs from tex, resize it
            if (bufferedTexture.width != tex.width || bufferedTexture.height != tex.height) {
                MTLTextureDescriptor* desc = [MTLTextureDescriptor
                                texture2DDescriptorWithPixelFormat:tex.pixelFormat
                                                             width:tex.width
                                                            height:tex.height
                                                         mipmapped:NO];
                bufferedTexture = [bufferedTexture.device newTextureWithDescriptor:desc];
            }

            int bpp = 4;
            switch (tex.pixelFormat) {
                case MTLPixelFormatDepth32Float:
                    bpp = 4;
                    break;
                case MTLPixelFormatRGBA16Unorm:
                case MTLPixelFormatRGBA16Float:
                    bpp = 8;
                    break;
                default:
                    break;
            }

            // Create a buffer to read from `tex`
            NSUInteger bytesPerRow = tex.width * bpp;
            NSUInteger bufferSize = bytesPerRow * tex.height;
            id<MTLBuffer> tempBuffer = [device newBufferWithLength:bufferSize
                                                           options:MTLResourceStorageModeShared];

            // Create a blit command encoder to copy the texture to the buffer
            id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
            [blitEncoder copyFromTexture:tex
                             sourceSlice:0
                             sourceLevel:0
                            sourceOrigin:MTLOriginMake(0, 0, 0)
                              sourceSize:MTLSizeMake(tex.width, tex.height, 1)
                                toBuffer:tempBuffer
                       destinationOffset:0
                  destinationBytesPerRow:bytesPerRow
                destinationBytesPerImage:bufferSize];
            [blitEncoder endEncoding];

            // Commit the command buffer and wait for it to complete
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];

            // Copy the buffer contents to the `bufferedTexture`
            // Assuming `bufferedTexture` has already been created with matching dimensions
            MTLRegion region = MTLRegionMake2D(0, 0, tex.width, tex.height);
            [bufferedTexture replaceRegion:region
                                mipmapLevel:0
                                  withBytes:tempBuffer.contents
                                bytesPerRow:bytesPerRow];

            ImGui::Image((ImTextureID) bufferedTexture,
                         ImVec2(width, height),
                         ImVec2(0, 1), ImVec2(1, 0));
#endif
        }
    }
}

void Viewport::_UpdateTransformGuizmo()
{
    SdfPathVector primPaths = GetModel()->GetSelection();
    if (primPaths.size() == 0 || primPaths[0].IsEmpty()) return;

    SdfPath primPath = primPaths[0];

    GfMatrix4d transform = _xformSceneIndex->GetXform(primPath);
    GfMatrix4f transformF(transform);

    GfMatrix4d view = _getCurViewMatrix();

    GfMatrix4f viewF(view);
    GfMatrix4f projF(_proj);

    ImGuizmo::Manipulate(viewF.data(), projF.data(), _curOperation, _curMode,
                         transformF.data());

    if (transformF != GfMatrix4f(transform))
        _xformSceneIndex->SetXform(primPath, GfMatrix4d(transformF));
}

void Viewport::_UpdateCubeGuizmo()
{
    GfMatrix4d view = _getCurViewMatrix();
    GfMatrix4f viewF(view);

    ImGuizmo::ViewManipulate(
        viewF.data(), 8.f,
        ImVec2(GetInnerRect().Max.x - 128, GetInnerRect().Min.y + 18),
        ImVec2(128, 128), IM_COL32_BLACK_TRANS);

    if (viewF != GfMatrix4f(view)) {
        view = GfMatrix4d(viewF);
        GfFrustum frustum;
        frustum.SetPositionAndRotationFromMatrix(view.GetInverse());
        _eye = frustum.GetPosition();
        _at = frustum.ComputeLookAtPoint();

        _UpdateActiveCamFromViewport();
    }
}

void Viewport::_UpdatePluginLabel()
{
    TfToken curPlugin = _engine->GetCurrentRendererPlugin();
    string pluginText = _engine->GetRendererPluginName(curPlugin);
    string text = pluginText;

    ImDrawList* draw_list = ImGui::GetWindowDrawList();

    ImVec2 textSize = ImGui::CalcTextSize(text.c_str());
    float margin = 6;
    float xPos = (GetInnerRect().Max.x - 64 - textSize.x / 2);
    float yPos = GetInnerRect().Min.y + margin * 2;
    // draw background color
    draw_list->AddRectFilled(
        ImVec2(xPos - margin, yPos - margin),
        ImVec2(xPos + textSize.x + margin, yPos + textSize.y + margin),
        ImColor(.0f, .0f, .0f, .2f), margin);
    // draw text
    draw_list->AddText(ImVec2(xPos, yPos), ImColor(1.f, 1.f, 1.f),
                       text.c_str());
}

void Viewport::_PanActiveCam(ImVec2 mouseDeltaPos)
{
    GfVec3d camFront = _at - _eye;
    GfVec3d camRight = GfCross(camFront, _up).GetNormalized();
    GfVec3d camUp = GfCross(camRight, camFront).GetNormalized();

    GfVec3d delta =
        camRight * -mouseDeltaPos.x / 100.f + camUp * mouseDeltaPos.y / 100.f;

    _eye += delta;
    _at += delta;

    _UpdateActiveCamFromViewport();
}

void Viewport::_OrbitActiveCam(ImVec2 mouseDeltaPos)
{
    GfRotation rot(_up, mouseDeltaPos.x / 2);
    GfMatrix4d rotMatrix = GfMatrix4d(1).SetRotate(rot);
    GfVec3d e = _eye - _at;
    GfVec4d vec4 = rotMatrix * GfVec4d(e[0], e[1], e[2], 1.f);
    _eye = _at + GfVec3d(vec4[0], vec4[1], vec4[2]);

    GfVec3d camFront = _at - _eye;
    GfVec3d camRight = GfCross(camFront, _up).GetNormalized();
    rot = GfRotation(camRight, mouseDeltaPos.y / 2);
    rotMatrix = GfMatrix4d(1).SetRotate(rot);
    e = _eye - _at;
    vec4 = rotMatrix * GfVec4d(e[0], e[1], e[2], 1.f);
    _eye = _at + GfVec3d(vec4[0], vec4[1], vec4[2]);

    _UpdateActiveCamFromViewport();
}

void Viewport::_ZoomActiveCam(ImVec2 mouseDeltaPos)
{
    GfVec3d camFront = (_at - _eye).GetNormalized();
    _eye += camFront * mouseDeltaPos.x / 100.f;

    _UpdateActiveCamFromViewport();
}

void Viewport::_ZoomActiveCam(float scrollWheel)
{
    GfVec3d camFront = (_at - _eye).GetNormalized();
    _eye += camFront * scrollWheel / 10.f;

    _UpdateActiveCamFromViewport();
}

void Viewport::_SetFreeCamAsActive()
{
    _activeCam = SdfPath();
}

void Viewport::_SetActiveCam(SdfPath primPath)
{
    _activeCam = primPath;
    _UpdateViewportFromActiveCam();
}

void Viewport::_UpdateViewportFromActiveCam()
{
    if (_activeCam.IsEmpty()) return;

    HdSceneIndexPrim prim = _sceneIndex->GetPrim(_activeCam);
    GfCamera gfCam = _ToGfCamera(prim);
    GfFrustum frustum = gfCam.GetFrustum();
    _eye = frustum.GetPosition();
    _at = frustum.ComputeLookAtPoint();
}

GfMatrix4d Viewport::_getCurViewMatrix()
{
    return GfMatrix4d().SetLookAt(_eye, _at, _up);
}

void Viewport::_UpdateActiveCamFromViewport()
{
    if (_activeCam.IsEmpty()) return;

    HdSceneIndexPrim prim = _sceneIndex->GetPrim(_activeCam);
    GfCamera gfCam = _ToGfCamera(prim);

    GfFrustum prevFrustum = gfCam.GetFrustum();

    GfMatrix4d view = _getCurViewMatrix();
    ;
    GfMatrix4d prevView = prevFrustum.ComputeViewMatrix();
    GfMatrix4d prevProj = prevFrustum.ComputeProjectionMatrix();

    if (view == prevView && _proj == prevProj) return;

    _xformSceneIndex->SetXform(_activeCam, view.GetInverse());
}

void Viewport::_UpdateProjection()
{
    float fov = _FREE_CAM_FOV;
    float nearPlane = _FREE_CAM_NEAR;
    float farPlane = _FREE_CAM_FAR;

    if (!_activeCam.IsEmpty()) {
        HdSceneIndexPrim prim = _sceneIndex->GetPrim(_activeCam);
        GfCamera gfCam = _ToGfCamera(prim);
        fov = gfCam.GetFieldOfView(GfCamera::FOVVertical);
        nearPlane = gfCam.GetClippingRange().GetMin();
        farPlane = gfCam.GetClippingRange().GetMax();
    }

    GfFrustum frustum;
    double aspectRatio = _GetViewportWidth() / _GetViewportHeight();
    frustum.SetPerspective(fov, true, aspectRatio, nearPlane, farPlane);
    _proj = frustum.ComputeProjectionMatrix();
}

GfCamera Viewport::_ToGfCamera(HdSceneIndexPrim prim)
{
    GfCamera cam;

    if (prim.primType != HdPrimTypeTokens->camera) return cam;

    HdSampledDataSource::Time time(0);

    HdXformSchema xformSchema = HdXformSchema::GetFromParent(prim.dataSource);

    GfMatrix4d xform =
        xformSchema.GetMatrix()->GetValue(time).Get<GfMatrix4d>();

    HdCameraSchema camSchema = HdCameraSchema::GetFromParent(prim.dataSource);

    TfToken projection =
        camSchema.GetProjection()->GetValue(time).Get<TfToken>();
    float hAperture =
        camSchema.GetHorizontalAperture()->GetValue(time).Get<float>();
    float vAperture =
        camSchema.GetVerticalAperture()->GetValue(time).Get<float>();
    float hApertureOffest =
        camSchema.GetHorizontalApertureOffset()->GetValue(time).Get<float>();
    float vApertureOffest =
        camSchema.GetVerticalApertureOffset()->GetValue(time).Get<float>();
    float focalLength =
        camSchema.GetFocalLength()->GetValue(time).Get<float>();
    GfVec2f clippingRange =
        camSchema.GetClippingRange()->GetValue(time).Get<GfVec2f>();

    cam.SetTransform(xform);
    cam.SetProjection(projection == HdCameraSchemaTokens->orthographic
                          ? GfCamera::Orthographic
                          : GfCamera::Perspective);
    cam.SetHorizontalAperture(hAperture / GfCamera::APERTURE_UNIT);
    cam.SetVerticalAperture(vAperture / GfCamera::APERTURE_UNIT);
    cam.SetHorizontalApertureOffset(hApertureOffest / GfCamera::APERTURE_UNIT);
    cam.SetVerticalApertureOffset(vApertureOffest / GfCamera::APERTURE_UNIT);
    cam.SetFocalLength(focalLength / GfCamera::FOCAL_LENGTH_UNIT);
    cam.SetClippingRange(GfRange1f(clippingRange[0], clippingRange[1]));

    return cam;
}

void Viewport::_FocusOnPrim(SdfPath primPath)
{
    if (primPath.IsEmpty()) return;

    HdSceneIndexPrim prim = _sceneIndex->GetPrim(primPath);

    HdExtentSchema extentSchema =
        HdExtentSchema::GetFromParent(prim.dataSource);
    if (!extentSchema.IsDefined()) {
        TF_WARN("Prim at %s has no extent; skipping focus.",
                primPath.GetAsString().c_str());
        return;
    }

    HdSampledDataSource::Time time(0);
    GfVec3d extentMin = extentSchema.GetMin()->GetValue(time).Get<GfVec3d>();
    GfVec3d extentMax = extentSchema.GetMax()->GetValue(time).Get<GfVec3d>();

    GfRange3d extentRange(extentMin, extentMax);

    _at = extentRange.GetMidpoint();
    _eye = _at + (_eye - _at).GetNormalized() *
                     extentRange.GetSize().GetLength() * 2;

    _UpdateActiveCamFromViewport();
}

void Viewport::_KeyPressEvent(ImGuiKey key)
{
    if (key == ImGuiKey_F) {
        SdfPathVector primPaths = GetModel()->GetSelection();
        if (primPaths.size() > 0) _FocusOnPrim(primPaths[0]);
    }
    else if (key == ImGuiKey_W) {
        _curOperation = ImGuizmo::TRANSLATE;
        _curMode = ImGuizmo::LOCAL;
    }
    else if (key == ImGuiKey_E) {
        _curOperation = ImGuizmo::ROTATE;
        _curMode = ImGuizmo::LOCAL;
    }
    else if (key == ImGuiKey_R) {
        _curOperation = ImGuizmo::SCALE;
        _curMode = ImGuizmo::LOCAL;
    }
}

void Viewport::_MouseMoveEvent(ImVec2 prevPos, ImVec2 curPos)
{
    ImVec2 deltaMousePos = curPos - prevPos;

    ImGuiIO& io = ImGui::GetIO();
    if (io.MouseWheel) _ZoomActiveCam(io.MouseWheel);

    if (ImGui::IsMouseDown(ImGuiMouseButton_Left) &&
        (ImGui::IsKeyDown(ImGuiKey_LeftAlt) ||
         ImGui::IsKeyDown(ImGuiKey_RightAlt))) {
        _OrbitActiveCam(deltaMousePos);
    }
    if (ImGui::IsMouseDown(ImGuiMouseButton_Left) &&
        (ImGui::IsKeyDown(ImGuiKey_LeftShift) ||
         ImGui::IsKeyDown(ImGuiKey_RightShift))) {
        _PanActiveCam(deltaMousePos);
    }
    if (ImGui::IsMouseDown(ImGuiMouseButton_Right) &&
        (ImGui::IsKeyDown(ImGuiKey_LeftAlt) ||
         ImGui::IsKeyDown(ImGuiKey_RightAlt))) {
        _ZoomActiveCam(deltaMousePos);
    }
}

void Viewport::_MouseReleaseEvent(ImGuiMouseButton_ button, ImVec2 mousePos)
{
    if (button == ImGuiMouseButton_Left) {
        ImVec2 delta = ImGui::GetMouseDragDelta(ImGuiMouseButton_Left);
        if (fabs(delta.x) + fabs(delta.y) < 0.001f) {
            GfVec2f gfMousePos(mousePos[0], mousePos[1]);
            SdfPath primPath = _engine->FindIntersection(gfMousePos);

            if (primPath.IsEmpty()) GetModel()->SetSelection({});
            else GetModel()->SetSelection({primPath});
        }
    }
}

void Viewport::_HoverInEvent()
{
    _gizmoWindowFlags |= ImGuiWindowFlags_NoMove;
}
void Viewport::_HoverOutEvent()
{
    _gizmoWindowFlags &= ~ImGuiWindowFlags_NoMove;
}

PXR_NAMESPACE_CLOSE_SCOPE
