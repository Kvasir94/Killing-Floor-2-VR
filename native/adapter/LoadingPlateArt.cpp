#include "LoadingPlateArt.h"

#include <windows.h>
#include <string>

namespace kf2vr::adapter {
namespace {

// KFGame.exe lives in <install>\Binaries\Win64; the splash ships with the game.
std::wstring SplashPath(const wchar_t* gameExecutable) {
    if (!gameExecutable || !*gameExecutable) return {};
    std::wstring path(gameExecutable);
    for (int up=0;up<3;++up) {
        const auto slash=path.find_last_of(L"\\/");
        if (slash==std::wstring::npos) return {};
        path.resize(slash);
    }
    return path+L"\\KFGame\\Splash\\PC\\Splash.bmp";
}

struct Gdi {
    HDC dc=nullptr,source=nullptr;
    HBITMAP target=nullptr,splash=nullptr;
    HGDIOBJ oldTarget=nullptr,oldSource=nullptr;
    ~Gdi() {
        if (source && oldSource) SelectObject(source,oldSource);
        if (dc && oldTarget) SelectObject(dc,oldTarget);
        if (splash) DeleteObject(splash);
        if (target) DeleteObject(target);
        if (source) DeleteDC(source);
        if (dc) DeleteDC(dc);
    }
};

void Fill(HDC dc,int left,int top,int right,int bottom,COLORREF color) {
    const RECT rect{left,top,right,bottom};
    HBRUSH brush=CreateSolidBrush(color);
    FillRect(dc,&rect,brush);
    DeleteObject(brush);
}

// KF2's menu type is a light geometric sans; Bahnschrift is the closest face
// every Windows 10/11 install carries. Spaced capitals, as the stock menus.
SIZE Text(HDC dc,const wchar_t* value,int height,COLORREF color,int left,int top,int right,UINT align) {
    HFONT font=CreateFontW(-height,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_TT_PRECIS,
        CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH|FF_SWISS,L"Bahnschrift");
    HGDIOBJ old=SelectObject(dc,font);
    const int extra=height/14;
    SetTextCharacterExtra(dc,extra);
    SetTextColor(dc,color);
    SIZE size{};
    GetTextExtentPoint32W(dc,value,lstrlenW(value),&size);
    size.cx-=extra; // no spacing after the last letter
    // Centre on the measured, spaced extent: DrawText's own centring ignores
    // the extra spacing and drifts the word right of its rule.
    if (align==DT_CENTER) left+=(right-left-size.cx)/2;
    RECT rect{left,top,right,top+height*2};
    DrawTextW(dc,value,-1,&rect,DT_LEFT|DT_TOP|DT_SINGLELINE|DT_NOPREFIX|DT_NOCLIP);
    SelectObject(dc,old);
    DeleteObject(font);
    return size;
}

} // namespace

LoadingPlateImage BrandedLoadingPlate(const wchar_t* gameExecutable,std::uint32_t width,std::uint32_t height) {
    LoadingPlateImage image;
    const std::wstring splashPath=SplashPath(gameExecutable);
    if (splashPath.empty() || width<256 || height<128) return image;
    Gdi gdi;
    gdi.splash=static_cast<HBITMAP>(LoadImageW(nullptr,splashPath.c_str(),IMAGE_BITMAP,0,0,LR_LOADFROMFILE|LR_CREATEDIBSECTION));
    if (!gdi.splash) return image;
    BITMAP splash{};
    if (!GetObjectW(gdi.splash,sizeof(splash),&splash) || splash.bmWidth<16 || splash.bmHeight<16) return image;
    gdi.dc=CreateCompatibleDC(nullptr);
    gdi.source=CreateCompatibleDC(nullptr);
    if (!gdi.dc || !gdi.source) return image;
    BITMAPINFO info{};
    info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth=static_cast<LONG>(width);
    info.bmiHeader.biHeight=-static_cast<LONG>(height); // top-down rows
    info.bmiHeader.biPlanes=1;
    info.bmiHeader.biBitCount=32;
    info.bmiHeader.biCompression=BI_RGB;
    void* bits=nullptr;
    gdi.target=CreateDIBSection(gdi.dc,&info,DIB_RGB_COLORS,&bits,nullptr,0);
    if (!gdi.target || !bits) return image;
    gdi.oldTarget=SelectObject(gdi.dc,gdi.target);
    gdi.oldSource=SelectObject(gdi.source,gdi.splash);
    SetBkMode(gdi.dc,TRANSPARENT);

    const int W=static_cast<int>(width),H=static_cast<int>(height);
    const int frameLeft=W*65/1000,frameRight=W-frameLeft;
    const int headerBottom=H*10/100,artBottom=H*74/100;
    // Dark maroon surround, a near-black header band and an opaque label panel.
    Fill(gdi.dc,0,0,W,H,RGB(16,8,11));
    Fill(gdi.dc,0,0,W,headerBottom,RGB(8,6,7));
    Fill(gdi.dc,frameLeft,artBottom,frameRight,H,RGB(9,6,8));
    Text(gdi.dc,L"VIRTUAL REALITY",H*36/1000,RGB(167,170,171),W*6/100,(headerBottom-H*36/1000)/2,W,DT_LEFT);

    // The stock artwork, full width and cropped vertically around its logo
    // band, so the whole KILLING FLOOR 2 wordmark stays inside the frame.
    const int artWidth=frameRight-frameLeft,artHeight=artBottom-headerBottom;
    int cropHeight=splash.bmHeight;
    int cropWidth=static_cast<int>(static_cast<long long>(cropHeight)*artWidth/artHeight);
    if (cropWidth>splash.bmWidth) {
        cropWidth=splash.bmWidth;
        cropHeight=static_cast<int>(static_cast<long long>(cropWidth)*artHeight/artWidth);
    }
    const int cropLeft=(splash.bmWidth-cropWidth)/2;
    int cropTop=splash.bmHeight*44/100-cropHeight/2; // the logo sits a little above centre
    if (cropTop<0) cropTop=0;
    if (cropTop+cropHeight>splash.bmHeight) cropTop=splash.bmHeight-cropHeight;
    SetStretchBltMode(gdi.dc,HALFTONE);
    SetBrushOrgEx(gdi.dc,0,0,nullptr);
    if (!StretchBlt(gdi.dc,frameLeft,headerBottom,artWidth,artHeight,gdi.source,cropLeft,cropTop,cropWidth,cropHeight,SRCCOPY))
        return image;

    // LOADING over KF2's red rule, then the product name. Static text only.
    const int wordTop=H*775/1000,wordHeight=H*85/1000;
    const SIZE word=Text(gdi.dc,L"LOADING",wordHeight,RGB(230,231,227),0,wordTop,W,DT_CENTER);
    const int ruleTop=wordTop+wordHeight+H*14/1000,ruleWidth=word.cx>0 ? word.cx : W/5;
    Fill(gdi.dc,(W-ruleWidth)/2,ruleTop,(W+ruleWidth)/2,ruleTop+(H/200>2 ? H/200 : 2),RGB(188,38,34));
    Text(gdi.dc,L"KILLING FLOOR 2 VR",H*42/1000,RGB(167,170,171),0,ruleTop+H*28/1000,W,DT_CENTER);
    GdiFlush();

    image.width=width; image.height=height;
    image.rgba.resize(static_cast<std::size_t>(width)*height*4);
    const auto* bgra=static_cast<const std::uint8_t*>(bits);
    for (std::size_t i=0;i<image.rgba.size();i+=4) {
        image.rgba[i]=bgra[i+2]; image.rgba[i+1]=bgra[i+1]; image.rgba[i+2]=bgra[i]; image.rgba[i+3]=255;
    }
    return image;
}

} // namespace kf2vr::adapter
