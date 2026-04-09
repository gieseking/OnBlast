#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <sys/types.h>

#include "MediaButtonVirtualAudioConstants.h"

#define MBITransportSharedMemoryMagic 0x4D424954U
#define MBITransportSharedMemoryVersion 2U
#define MBITransportSharedMemoryRingFrameCapacity 96000U

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t sampleRate;
    uint32_t bufferFrameSize;
    uint32_t channelCount;
    uint32_t ringFrameCapacity;
    uint32_t muted;
    uint32_t running;
    uint32_t sourceConnected;
    _Atomic uint64_t writeFrameCounter;
    float ringBuffer[MBITransportSharedMemoryRingFrameCapacity];
} MBITransportSharedMemory;

const char *MBITransportSharedMemoryPath(void);
size_t MBITransportSharedMemorySize(void);
int MBITransportOpenSharedMemory(int createIfNeeded, int *outFileDescriptor, MBITransportSharedMemory **outSharedMemory);
void MBITransportCloseSharedMemory(int fileDescriptor, MBITransportSharedMemory *sharedMemory);
void MBITransportInitialize(MBITransportSharedMemory *sharedMemory);
void MBITransportSetSampleRate(MBITransportSharedMemory *sharedMemory, uint32_t sampleRate);
void MBITransportSetBufferFrameSize(MBITransportSharedMemory *sharedMemory, uint32_t bufferFrameSize);
void MBITransportSetMuted(MBITransportSharedMemory *sharedMemory, uint32_t muted);
void MBITransportSetRunning(MBITransportSharedMemory *sharedMemory, uint32_t running);
void MBITransportSetSourceConnected(MBITransportSharedMemory *sharedMemory, uint32_t sourceConnected);
void MBITransportWriteMonoFloat(MBITransportSharedMemory *sharedMemory, const float *frames, uint32_t frameCount);
void MBITransportReadMonoFloat(MBITransportSharedMemory *sharedMemory, float *destination, uint32_t frameCount, uint64_t *ioReadFrameCounter);
