#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#include "OBTransportShared.h"
#include "OnBlastVirtualAudioConstants.h"

enum {
    kMBIObjectID_Device = 2,
    kMBIObjectID_Stream_Input = 3
};

enum {
    kMBIChannelCount = 1,
    kMBISafetyOffsetFrames = 0,
    kMBILatencyFrames = 0,
    kMBIBufferFrameSize = 512,
    kMBIZeroTimeStampPeriod = 16384
};

static const Float64 kMBIDefaultSampleRate = 48000.0;
static const char *kMBIDeviceUID = "com.gieseking.OnBlast.VirtualMicrophone.Device";
static const char *kMBIDeviceModelUID = "com.gieseking.OnBlast.VirtualMicrophone.Model";
static const char *kMBIPlugInName = "OnBlast Virtual Audio Plug-In";
static const char *kMBIManufacturerName = "OnBlast";
static const char *kMBIStreamName = "OnBlast Virtual Input Stream";

typedef struct {
    AudioServerPlugInDriverInterface *mDriverInterface;
    atomic_uint mRefCount;
} OBDriverRef;

typedef struct {
    pthread_mutex_t mutex;
    AudioServerPlugInHostRef host;
    UInt32 ioClientCount;
    UInt64 clockSeed;
    UInt64 anchorHostTime;
    int sharedMemoryFileDescriptor;
    OBTransportSharedMemory *sharedMemory;
    UInt64 readFrameCounter;
} OBDriverState;

static HRESULT STDMETHODCALLTYPE OB_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG STDMETHODCALLTYPE OB_AddRef(void *inDriver);
static ULONG STDMETHODCALLTYPE OB_Release(void *inDriver);
static OSStatus STDMETHODCALLTYPE OB_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus STDMETHODCALLTYPE OB_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus STDMETHODCALLTYPE OB_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus STDMETHODCALLTYPE OB_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus STDMETHODCALLTYPE OB_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus STDMETHODCALLTYPE OB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus STDMETHODCALLTYPE OB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean STDMETHODCALLTYPE OB_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus STDMETHODCALLTYPE OB_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus STDMETHODCALLTYPE OB_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus STDMETHODCALLTYPE OB_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus STDMETHODCALLTYPE OB_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus STDMETHODCALLTYPE OB_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE OB_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus STDMETHODCALLTYPE OB_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus STDMETHODCALLTYPE OB_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus STDMETHODCALLTYPE OB_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus STDMETHODCALLTYPE OB_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus STDMETHODCALLTYPE OB_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static void OB_EnsureSharedMemoryMappedLocked(void);

static AudioServerPlugInDriverInterface gMBIDriverInterface = {
    NULL,
    OB_QueryInterface,
    OB_AddRef,
    OB_Release,
    OB_Initialize,
    OB_CreateDevice,
    OB_DestroyDevice,
    OB_AddDeviceClient,
    OB_RemoveDeviceClient,
    OB_PerformDeviceConfigurationChange,
    OB_AbortDeviceConfigurationChange,
    OB_HasProperty,
    OB_IsPropertySettable,
    OB_GetPropertyDataSize,
    OB_GetPropertyData,
    OB_SetPropertyData,
    OB_StartIO,
    OB_StopIO,
    OB_GetZeroTimeStamp,
    OB_WillDoIOOperation,
    OB_BeginIOOperation,
    OB_DoIOOperation,
    OB_EndIOOperation
};

static OBDriverRef gMBIDriverRef = {
    &gMBIDriverInterface,
    ATOMIC_VAR_INIT(1)
};

static OBDriverState gMBIDriverState = {
    PTHREAD_MUTEX_INITIALIZER,
    NULL,
    0,
    1,
    0,
    -1,
    NULL,
    0
};

static Boolean OB_UUIDsEqual(REFIID inUUID, CFUUIDRef inReferenceUUID) {
    const CFUUIDBytes referenceBytes = CFUUIDGetUUIDBytes(inReferenceUUID);
    return memcmp(&inUUID, &referenceBytes, sizeof(CFUUIDBytes)) == 0;
}

static UInt64 OB_HostTicksPerSecond(void) {
    static UInt64 cachedTicksPerSecond = 0;
    if (cachedTicksPerSecond == 0) {
        mach_timebase_info_data_t timebaseInfo;
        mach_timebase_info(&timebaseInfo);
        cachedTicksPerSecond = (UInt64)((1000000000.0L * (long double)timebaseInfo.denom) / (long double)timebaseInfo.numer);
    }

    return cachedTicksPerSecond;
}

static AudioClassID OB_ClassIDForObject(AudioObjectID inObjectID) {
    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            return kAudioPlugInClassID;
        case kMBIObjectID_Device:
            return kAudioDeviceClassID;
        case kMBIObjectID_Stream_Input:
            return kAudioStreamClassID;
        default:
            return kAudioObjectClassIDWildcard;
    }
}

static OSStatus OB_ErrorForObject(AudioObjectID inObjectID) {
    switch (inObjectID) {
        case kMBIObjectID_Device:
            return kAudioHardwareBadDeviceError;
        case kMBIObjectID_Stream_Input:
            return kAudioHardwareBadStreamError;
        default:
            return kAudioHardwareBadObjectError;
    }
}

static Boolean OB_IsValidObjectID(AudioObjectID inObjectID) {
    return inObjectID == kAudioObjectPlugInObject ||
        inObjectID == kMBIObjectID_Device ||
        inObjectID == kMBIObjectID_Stream_Input;
}

static Boolean OB_ObjectMatchesClass(AudioObjectID inObjectID, UInt32 inQualifierDataSize, const void *inQualifierData) {
    if (inQualifierDataSize == 0 || inQualifierData == NULL) {
        return true;
    }

    const UInt32 qualifierCount = inQualifierDataSize / sizeof(AudioClassID);
    const AudioClassID *classIDs = (const AudioClassID *)inQualifierData;
    const AudioClassID objectClassID = OB_ClassIDForObject(inObjectID);

    for (UInt32 index = 0; index < qualifierCount; ++index) {
        const AudioClassID requestedClassID = classIDs[index];
        if (requestedClassID == kAudioObjectClassIDWildcard ||
            requestedClassID == kAudioObjectClassID ||
            requestedClassID == objectClassID) {
            return true;
        }
    }

    return false;
}

static CFStringRef OB_CopyStaticString(CFStringRef inString) {
    return (CFStringRef)CFRetain(inString);
}

static CFStringRef OB_CopyCString(const char *inString) {
    return CFStringCreateWithCString(kCFAllocatorDefault, inString, kCFStringEncodingUTF8);
}

static Boolean OB_CFStringEqualsCString(CFStringRef inString, const char *inCString) {
    Boolean isEqual = false;
    CFStringRef comparisonString = OB_CopyCString(inCString);
    if (inString != NULL && comparisonString != NULL) {
        isEqual = CFStringCompare(inString, comparisonString, 0) == kCFCompareEqualTo;
    }
    if (comparisonString != NULL) {
        CFRelease(comparisonString);
    }
    return isEqual;
}

static Float64 OB_CurrentSampleRateLocked(void) {
    OB_EnsureSharedMemoryMappedLocked();
    if (gMBIDriverState.sharedMemory != NULL && gMBIDriverState.sharedMemory->sampleRate >= 8000U) {
        return (Float64)gMBIDriverState.sharedMemory->sampleRate;
    }

    return kMBIDefaultSampleRate;
}

static Float64 OB_CurrentSampleRate(void) {
    Float64 sampleRate = 0;
    pthread_mutex_lock(&gMBIDriverState.mutex);
    sampleRate = OB_CurrentSampleRateLocked();
    pthread_mutex_unlock(&gMBIDriverState.mutex);
    return sampleRate;
}

static UInt32 OB_CurrentBufferFrameSizeLocked(void) {
    OB_EnsureSharedMemoryMappedLocked();
    if (gMBIDriverState.sharedMemory != NULL && gMBIDriverState.sharedMemory->bufferFrameSize > 0) {
        return gMBIDriverState.sharedMemory->bufferFrameSize;
    }

    return kMBIBufferFrameSize;
}

static UInt32 OB_CurrentBufferFrameSize(void) {
    UInt32 bufferFrameSize = 0;
    pthread_mutex_lock(&gMBIDriverState.mutex);
    bufferFrameSize = OB_CurrentBufferFrameSizeLocked();
    pthread_mutex_unlock(&gMBIDriverState.mutex);
    return bufferFrameSize;
}

static AudioStreamBasicDescription OB_StreamFormat(Float64 inSampleRate) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = inSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    format.mBytesPerPacket = sizeof(Float32) * kMBIChannelCount;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32) * kMBIChannelCount;
    format.mChannelsPerFrame = kMBIChannelCount;
    format.mBitsPerChannel = sizeof(Float32) * 8;
    return format;
}

static AudioStreamRangedDescription OB_StreamRangedDescription(void) {
    AudioStreamRangedDescription rangedDescription;
    memset(&rangedDescription, 0, sizeof(rangedDescription));
    const Float64 sampleRate = OB_CurrentSampleRate();
    rangedDescription.mFormat = OB_StreamFormat(sampleRate);
    rangedDescription.mSampleRateRange.mMinimum = sampleRate;
    rangedDescription.mSampleRateRange.mMaximum = sampleRate;
    return rangedDescription;
}

static void OB_ResetTimelineLocked(void) {
    gMBIDriverState.anchorHostTime = mach_absolute_time();
    gMBIDriverState.clockSeed += 1;
}

static void OB_GetZeroTimeStampSnapshot(Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    UInt64 anchorHostTime = 0;
    UInt64 clockSeed = 0;
    Float64 sampleRate = kMBIDefaultSampleRate;

    pthread_mutex_lock(&gMBIDriverState.mutex);
    if (gMBIDriverState.anchorHostTime == 0) {
        OB_ResetTimelineLocked();
    }
    anchorHostTime = gMBIDriverState.anchorHostTime;
    clockSeed = gMBIDriverState.clockSeed;
    sampleRate = OB_CurrentSampleRateLocked();
    pthread_mutex_unlock(&gMBIDriverState.mutex);

    const UInt64 hostTicksPerSecond = OB_HostTicksPerSecond();
    const UInt64 now = mach_absolute_time();
    const long double elapsedHostTicks = (long double)(now - anchorHostTime);
    const long double elapsedFrames = (elapsedHostTicks * (long double)sampleRate) / (long double)hostTicksPerSecond;
    const UInt64 elapsedPeriods = (UInt64)(elapsedFrames / (long double)kMBIZeroTimeStampPeriod);
    const Float64 sampleTime = (Float64)(elapsedPeriods * kMBIZeroTimeStampPeriod);
    const UInt64 hostTime = anchorHostTime + (UInt64)(((long double)sampleTime * (long double)hostTicksPerSecond) / (long double)sampleRate);

    *outSampleTime = sampleTime;
    *outHostTime = hostTime;
    *outSeed = clockSeed;
}

static void OB_NotifyPropertiesChanged(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
    AudioServerPlugInHostRef host = NULL;

    pthread_mutex_lock(&gMBIDriverState.mutex);
    host = gMBIDriverState.host;
    pthread_mutex_unlock(&gMBIDriverState.mutex);

    if (host != NULL && host->PropertiesChanged != NULL) {
        host->PropertiesChanged(host, inObjectID, inNumberAddresses, inAddresses);
    }
}

static void OB_EnsureSharedMemoryMappedLocked(void) {
    if (gMBIDriverState.sharedMemory != NULL) {
        return;
    }

    int fileDescriptor = -1;
    OBTransportSharedMemory *sharedMemory = NULL;
    if (OBTransportOpenSharedMemory(0, &fileDescriptor, &sharedMemory) == 0) {
        gMBIDriverState.sharedMemoryFileDescriptor = fileDescriptor;
        gMBIDriverState.sharedMemory = sharedMemory;
    }
}

static OSStatus OB_WriteAudioObjectIDs(AudioObjectID *outData, UInt32 inDataSize, UInt32 *outDataSize, const AudioObjectID *inObjectIDs, UInt32 inObjectCount) {
    const UInt32 bytesToCopy = inObjectCount * (UInt32)sizeof(AudioObjectID);
    if (inDataSize < bytesToCopy) {
        return kAudioHardwareBadPropertySizeError;
    }

    if (bytesToCopy > 0) {
        memcpy(outData, inObjectIDs, bytesToCopy);
    }

    *outDataSize = bytesToCopy;
    return kAudioHardwareNoError;
}

static Boolean OB_IsInputScope(AudioObjectPropertyScope inScope) {
    return inScope == kAudioObjectPropertyScopeInput || inScope == kAudioObjectPropertyScopeGlobal;
}

static UInt32 OB_StreamConfigurationDataSize(AudioObjectPropertyScope inScope) {
    if (OB_IsInputScope(inScope)) {
        return (UInt32)(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer));
    }

    return (UInt32)offsetof(AudioBufferList, mBuffers);
}

static OSStatus OB_WriteStreamConfiguration(AudioObjectPropertyScope inScope, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    const UInt32 requiredDataSize = OB_StreamConfigurationDataSize(inScope);
    if (inDataSize < requiredDataSize) {
        return kAudioHardwareBadPropertySizeError;
    }

    AudioBufferList *bufferList = (AudioBufferList *)outData;
    if (OB_IsInputScope(inScope)) {
        bufferList->mNumberBuffers = 1;
        bufferList->mBuffers[0].mNumberChannels = kMBIChannelCount;
        bufferList->mBuffers[0].mDataByteSize = 0;
        bufferList->mBuffers[0].mData = NULL;
    } else {
        bufferList->mNumberBuffers = 0;
    }

    *outDataSize = requiredDataSize;
    return kAudioHardwareNoError;
}

static Boolean OB_DeviceHasProperty(const AudioObjectPropertyAddress *inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyCreator:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyPlugIn:
        case kAudioDevicePropertyConfigurationApplication:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceIsRunningSomewhere:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyActualSampleRate:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyHogMode:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyClockAlgorithm:
        case kAudioDevicePropertyClockIsStable:
            return true;
        default:
            return false;
    }
}

static Boolean OB_StreamHasProperty(const AudioObjectPropertyAddress *inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyCreator:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean OB_PlugInHasProperty(const AudioObjectPropertyAddress *inAddress) {
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyCreator:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static HRESULT STDMETHODCALLTYPE OB_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) {
        return E_POINTER;
    }

    if (OB_UUIDsEqual(inUUID, IUnknownUUID) || OB_UUIDsEqual(inUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        OB_AddRef(inDriver);
        *outInterface = inDriver;
        return S_OK;
    }

    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE OB_AddRef(void *inDriver) {
    (void)inDriver;
    return atomic_fetch_add_explicit(&gMBIDriverRef.mRefCount, 1, memory_order_relaxed) + 1;
}

static ULONG STDMETHODCALLTYPE OB_Release(void *inDriver) {
    (void)inDriver;
    const UInt32 previousRefCount = atomic_fetch_sub_explicit(&gMBIDriverRef.mRefCount, 1, memory_order_relaxed);
    if (previousRefCount == 0) {
        atomic_store_explicit(&gMBIDriverRef.mRefCount, 0, memory_order_relaxed);
        return 0;
    }
    return previousRefCount - 1;
}

static OSStatus STDMETHODCALLTYPE OB_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver;

    pthread_mutex_lock(&gMBIDriverState.mutex);
    gMBIDriverState.host = inHost;
    gMBIDriverState.ioClientCount = 0;
    gMBIDriverState.clockSeed = 1;
    gMBIDriverState.anchorHostTime = mach_absolute_time();
    gMBIDriverState.readFrameCounter = 0;
    pthread_mutex_unlock(&gMBIDriverState.mutex);

    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver;
    (void)inDescription;
    (void)inClientInfo;
    (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus STDMETHODCALLTYPE OB_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver;
    (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus STDMETHODCALLTYPE OB_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kMBIObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus STDMETHODCALLTYPE OB_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver;
    (void)inClientInfo;
    return inDeviceObjectID == kMBIObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus STDMETHODCALLTYPE OB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver;
    (void)inChangeAction;
    (void)inChangeInfo;
    return inDeviceObjectID == kMBIObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus STDMETHODCALLTYPE OB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver;
    (void)inChangeAction;
    (void)inChangeInfo;
    return inDeviceObjectID == kMBIObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static Boolean STDMETHODCALLTYPE OB_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver;
    (void)inClientProcessID;

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            return OB_PlugInHasProperty(inAddress);
        case kMBIObjectID_Device:
            return OB_DeviceHasProperty(inAddress);
        case kMBIObjectID_Stream_Input:
            return OB_StreamHasProperty(inAddress);
        default:
            return false;
    }
}

static OSStatus STDMETHODCALLTYPE OB_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver;
    (void)inClientProcessID;

    if (outIsSettable == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    if (!OB_IsValidObjectID(inObjectID)) {
        return OB_ErrorForObject(inObjectID);
    }

    if (!OB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    *outIsSettable = false;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver;
    (void)inClientProcessID;

    if (outDataSize == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    if (!OB_IsValidObjectID(inObjectID)) {
        return OB_ErrorForObject(inObjectID);
    }

    if (!OB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCreator:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyBundleID:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = OB_ObjectMatchesClass(kMBIObjectID_Device, inQualifierDataSize, inQualifierData) ? sizeof(AudioObjectID) : 0;
                    return kAudioHardwareNoError;
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                default:
                    break;
            }
            break;

        case kMBIObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyPlugIn:
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceIsRunningSomewhere:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyBufferFrameSize:
                case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                case kAudioDevicePropertyIsHidden:
                case kAudioDevicePropertyHogMode:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyClockAlgorithm:
                case kAudioDevicePropertyClockIsStable:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCreator:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyConfigurationApplication:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCustomPropertyInfoList:
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                    *outDataSize = OB_IsInputScope(inAddress->mScope) && OB_ObjectMatchesClass(kMBIObjectID_Stream_Input, inQualifierDataSize, inQualifierData) ? sizeof(AudioObjectID) : 0;
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyActualSampleRate:
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyBufferFrameSizeRange:
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                case kAudioDevicePropertyStreamConfiguration:
                    *outDataSize = OB_StreamConfigurationDataSize(inAddress->mScope);
                    return kAudioHardwareNoError;
                default:
                    break;
            }
            break;

        case kMBIObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCreator:
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;
                default:
                    break;
            }
            break;
        default:
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus STDMETHODCALLTYPE OB_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver;
    (void)inClientProcessID;

    if (outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    if (!OB_IsValidObjectID(inObjectID)) {
        return OB_ErrorForObject(inObjectID);
    }

    if (!OB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) {
        return kAudioHardwareUnknownPropertyError;
    }

    switch (inObjectID) {
        case kAudioObjectPlugInObject:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioClassID *)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioClassID *)outData = kAudioPlugInClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioObjectID *)outData = kAudioObjectUnknown;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyCreator:
                case kAudioPlugInPropertyBundleID:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyStaticString(CFSTR(OBVirtualAudioPlugInBundleIdentifier));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyName:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIPlugInName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIManufacturerName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList: {
                    if (OB_ObjectMatchesClass(kMBIObjectID_Device, inQualifierDataSize, inQualifierData)) {
                        const AudioObjectID objectID = kMBIObjectID_Device;
                        return OB_WriteAudioObjectIDs((AudioObjectID *)outData, inDataSize, outDataSize, &objectID, 1);
                    }
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                }

                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }

                    AudioObjectID deviceObjectID = kAudioObjectUnknown;
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                        CFStringRef requestedUID = *(const CFStringRef *)inQualifierData;
                        if (OB_CFStringEqualsCString(requestedUID, kMBIDeviceUID)) {
                            deviceObjectID = kMBIObjectID_Device;
                        }
                    }

                    *(AudioObjectID *)outData = deviceObjectID;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;
                }

                case kAudioPlugInPropertyResourceBundle:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyStaticString(CFSTR("."));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                default:
                    break;
            }
            break;

        case kMBIObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioClassID *)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioClassID *)outData = kAudioDeviceClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyOwner:
                case kAudioDevicePropertyPlugIn:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioObjectID *)outData = kAudioObjectPlugInObject;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyCreator:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyStaticString(CFSTR(OBVirtualAudioPlugInBundleIdentifier));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyName:
                case kAudioObjectPropertyModelName:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyStaticString(CFSTR(OBVirtualAudioDeviceName));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIManufacturerName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams: {
                    if (OB_IsInputScope(inAddress->mScope) && OB_ObjectMatchesClass(kMBIObjectID_Stream_Input, inQualifierDataSize, inQualifierData)) {
                        const AudioObjectID objectID = kMBIObjectID_Stream_Input;
                        return OB_WriteAudioObjectIDs((AudioObjectID *)outData, inDataSize, outDataSize, &objectID, 1);
                    }
                    *outDataSize = 0;
                    return kAudioHardwareNoError;
                }

                case kAudioObjectPropertyControlList:
                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyConfigurationApplication:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyStaticString(CFSTR("com.apple.audio.AudioMIDISetup"));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyDeviceUID:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIDeviceUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyModelUID:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIDeviceModelUID);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyTransportType:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyRelatedDevices: {
                    const AudioObjectID objectID = kMBIObjectID_Device;
                    return OB_WriteAudioObjectIDs((AudioObjectID *)outData, inDataSize, outDataSize, &objectID, 1);
                }

                case kAudioDevicePropertyClockDomain:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyDeviceIsAlive:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceIsRunningSomewhere: {
                    UInt32 running = 0;
                    pthread_mutex_lock(&gMBIDriverState.mutex);
                    running = gMBIDriverState.ioClientCount > 0 ? 1U : 0U;
                    pthread_mutex_unlock(&gMBIDriverState.mutex);

                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = running;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = OB_IsInputScope(inAddress->mScope) ? 1U : 0U;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyLatency:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = kMBILatencyFrames;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertySafetyOffset:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = kMBISafetyOffsetFrames;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyNominalSampleRate:
                case kAudioDevicePropertyActualSampleRate:
                    if (inDataSize < sizeof(Float64)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(Float64 *)outData = OB_CurrentSampleRate();
                    *outDataSize = sizeof(Float64);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyAvailableNominalSampleRates:
                case kAudioDevicePropertyBufferFrameSizeRange: {
                    if (inDataSize < sizeof(AudioValueRange)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    const Float64 sampleRate = OB_CurrentSampleRate();
                    const Float64 bufferFrameSize = (Float64)OB_CurrentBufferFrameSize();
                    ((AudioValueRange *)outData)->mMinimum =
                        inAddress->mSelector == kAudioDevicePropertyBufferFrameSizeRange ? bufferFrameSize : sampleRate;
                    ((AudioValueRange *)outData)->mMaximum =
                        inAddress->mSelector == kAudioDevicePropertyBufferFrameSizeRange ? bufferFrameSize : sampleRate;
                    *outDataSize = sizeof(AudioValueRange);
                    return kAudioHardwareNoError;
                }

                case kAudioDevicePropertyBufferFrameSize:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = OB_CurrentBufferFrameSize();
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyUsesVariableBufferFrameSizes:
                case kAudioDevicePropertyIsHidden:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyHogMode:
                    if (inDataSize < sizeof(pid_t)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(pid_t *)outData = -1;
                    *outDataSize = sizeof(pid_t);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyStreamConfiguration:
                    return OB_WriteStreamConfiguration(inAddress->mScope, inDataSize, outDataSize, outData);

                case kAudioDevicePropertyZeroTimeStampPeriod:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = kMBIZeroTimeStampPeriod;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyClockAlgorithm:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = kAudioDeviceClockAlgorithmRaw;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioDevicePropertyClockIsStable:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                default:
                    break;
            }
            break;

        case kMBIObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioClassID *)outData = kAudioObjectClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyClass:
                    if (inDataSize < sizeof(AudioClassID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioClassID *)outData = kAudioStreamClassID;
                    *outDataSize = sizeof(AudioClassID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyOwner:
                    if (inDataSize < sizeof(AudioObjectID)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioObjectID *)outData = kMBIObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyCreator:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyStaticString(CFSTR(OBVirtualAudioPlugInBundleIdentifier));
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyName:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIStreamName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyManufacturer:
                    if (inDataSize < sizeof(CFStringRef)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(CFStringRef *)outData = OB_CopyCString(kMBIManufacturerName);
                    *outDataSize = sizeof(CFStringRef);
                    return kAudioHardwareNoError;

                case kAudioObjectPropertyCustomPropertyInfoList:
                    *outDataSize = 0;
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyIsActive:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyDirection:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyTerminalType:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = kAudioStreamTerminalTypeMicrophone;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyStartingChannel:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 1;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyLatency:
                    if (inDataSize < sizeof(UInt32)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(UInt32 *)outData = 0;
                    *outDataSize = sizeof(UInt32);
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioStreamBasicDescription *)outData = OB_StreamFormat(OB_CurrentSampleRate());
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return kAudioHardwareNoError;

                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    if (inDataSize < sizeof(AudioStreamRangedDescription)) {
                        return kAudioHardwareBadPropertySizeError;
                    }
                    *(AudioStreamRangedDescription *)outData = OB_StreamRangedDescription();
                    *outDataSize = sizeof(AudioStreamRangedDescription);
                    return kAudioHardwareNoError;

                default:
                    break;
            }
            break;

        default:
            break;
    }

    return kAudioHardwareUnknownPropertyError;
}

static OSStatus STDMETHODCALLTYPE OB_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver;
    (void)inObjectID;
    (void)inClientProcessID;
    (void)inAddress;
    (void)inQualifierDataSize;
    (void)inQualifierData;
    (void)inDataSize;
    (void)inData;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus STDMETHODCALLTYPE OB_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kMBIObjectID_Device) {
        return kAudioHardwareBadDeviceError;
    }

    Boolean runningStateChanged = false;
    pthread_mutex_lock(&gMBIDriverState.mutex);
    OB_EnsureSharedMemoryMappedLocked();
    if (gMBIDriverState.ioClientCount == 0) {
        OB_ResetTimelineLocked();
        gMBIDriverState.readFrameCounter = 0;
        runningStateChanged = true;
    }
    gMBIDriverState.ioClientCount += 1;
    pthread_mutex_unlock(&gMBIDriverState.mutex);

    if (runningStateChanged) {
        const AudioObjectPropertyAddress addresses[] = {
            { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
        };
        OB_NotifyPropertiesChanged(kMBIObjectID_Device, 2, addresses);
    }

    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kMBIObjectID_Device) {
        return kAudioHardwareBadDeviceError;
    }

    Boolean runningStateChanged = false;
    pthread_mutex_lock(&gMBIDriverState.mutex);
    if (gMBIDriverState.ioClientCount > 0) {
        gMBIDriverState.ioClientCount -= 1;
        if (gMBIDriverState.ioClientCount == 0) {
            gMBIDriverState.readFrameCounter = 0;
            runningStateChanged = true;
        }
    }
    pthread_mutex_unlock(&gMBIDriverState.mutex);

    if (runningStateChanged) {
        const AudioObjectPropertyAddress addresses[] = {
            { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
        };
        OB_NotifyPropertiesChanged(kMBIObjectID_Device, 2, addresses);
    }

    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kMBIObjectID_Device) {
        return kAudioHardwareBadDeviceError;
    }

    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    OB_GetZeroTimeStampSnapshot(outSampleTime, outHostTime, outSeed);
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver;
    (void)inClientID;

    if (inDeviceObjectID != kMBIObjectID_Device) {
        return kAudioHardwareBadDeviceError;
    }

    if (outWillDo == NULL || outWillDoInPlace == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kMBIObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

static OSStatus STDMETHODCALLTYPE OB_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver;
    (void)inClientID;
    (void)inIOCycleInfo;
    (void)ioSecondaryBuffer;

    if (inDeviceObjectID != kMBIObjectID_Device) {
        return kAudioHardwareBadDeviceError;
    }

    if (inStreamObjectID != kMBIObjectID_Stream_Input) {
        return kAudioHardwareBadStreamError;
    }

    if (inOperationID != kAudioServerPlugInIOOperationReadInput) {
        return kAudioHardwareNoError;
    }

    if (ioMainBuffer != NULL) {
        pthread_mutex_lock(&gMBIDriverState.mutex);
        OB_EnsureSharedMemoryMappedLocked();
        OBTransportReadMonoFloat(
            gMBIDriverState.sharedMemory,
            (float *)ioMainBuffer,
            inIOBufferFrameSize,
            &gMBIDriverState.readFrameCounter
        );
        pthread_mutex_unlock(&gMBIDriverState.mutex);
    }

    return kAudioHardwareNoError;
}

static OSStatus STDMETHODCALLTYPE OB_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver;
    (void)inClientID;
    (void)inOperationID;
    (void)inIOBufferFrameSize;
    (void)inIOCycleInfo;
    return inDeviceObjectID == kMBIObjectID_Device ? kAudioHardwareNoError : kAudioHardwareBadDeviceError;
}

void *OnBlastVirtualAudioFactory(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;

    if (requestedTypeUUID == NULL || !CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }

    OB_AddRef(&gMBIDriverRef);
    return &gMBIDriverRef;
}

void *AudioServerPlugInMain(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    return OnBlastVirtualAudioFactory(allocator, requestedTypeUUID);
}
