//
//  LibrtmpBridge.h
//  HPLiveKit
//
//  Created by Huiping Guo on 2020/03/01.
//

#import <Foundation/Foundation.h>
#import <pili_librtmp/pili-librtmp-umbrella.h>

#define SAVC(x)    static const PILI_AVal av_ ## x = AVC(#x)

static const PILI_AVal av_setDataFrame = AVC("@setDataFrame");
static const PILI_AVal av_SDKVersion = AVC("LFLiveKit 2.4.0");
SAVC(onMetaData);
SAVC(duration);
SAVC(width);
SAVC(height);
SAVC(videocodecid);
SAVC(videodatarate);
SAVC(framerate);
SAVC(audiocodecid);
SAVC(audiodatarate);
SAVC(audiosamplerate);
SAVC(audiosamplesize);
//SAVC(audiochannels);
SAVC(stereo);
SAVC(encoder);
//SAVC(av_stereo);
SAVC(fileSize);
SAVC(avc1);
SAVC(mp4a);

@interface LibrtmpBridge : NSObject


@end
