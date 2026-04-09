#include "MBITransportShared.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *kMBITransportSharedMemoryPath = "/tmp/com.gieseking.MediaButtonInterceptor.VirtualMicTransport.shared";
static const uint32_t kMBITransportDefaultSampleRate = 48000U;
static const uint32_t kMBITransportDefaultBufferFrameSize = 512U;
static const uint32_t kMBITransportChannelCount = 1U;

const char *MBITransportSharedMemoryPath(void) {
    return kMBITransportSharedMemoryPath;
}

size_t MBITransportSharedMemorySize(void) {
    return sizeof(MBITransportSharedMemory);
}

void MBITransportInitialize(MBITransportSharedMemory *sharedMemory) {
    if (sharedMemory == NULL) {
        return;
    }

    memset(sharedMemory, 0, sizeof(MBITransportSharedMemory));
    sharedMemory->magic = MBITransportSharedMemoryMagic;
    sharedMemory->version = MBITransportSharedMemoryVersion;
    sharedMemory->sampleRate = kMBITransportDefaultSampleRate;
    sharedMemory->bufferFrameSize = kMBITransportDefaultBufferFrameSize;
    sharedMemory->channelCount = kMBITransportChannelCount;
    sharedMemory->ringFrameCapacity = MBITransportSharedMemoryRingFrameCapacity;
    atomic_store_explicit(&sharedMemory->writeFrameCounter, 0, memory_order_release);
}

static void MBITransportEnsureInitialized(MBITransportSharedMemory *sharedMemory) {
    if (sharedMemory == NULL) {
        return;
    }

    if (sharedMemory->magic != MBITransportSharedMemoryMagic ||
        sharedMemory->version != MBITransportSharedMemoryVersion ||
        sharedMemory->ringFrameCapacity != MBITransportSharedMemoryRingFrameCapacity ||
        sharedMemory->channelCount != kMBITransportChannelCount) {
        MBITransportInitialize(sharedMemory);
    } else {
        if (sharedMemory->sampleRate == 0) {
            sharedMemory->sampleRate = kMBITransportDefaultSampleRate;
        }
        if (sharedMemory->bufferFrameSize == 0) {
            sharedMemory->bufferFrameSize = kMBITransportDefaultBufferFrameSize;
        }
    }
}

int MBITransportOpenSharedMemory(int createIfNeeded, int *outFileDescriptor, MBITransportSharedMemory **outSharedMemory) {
    if (outFileDescriptor == NULL || outSharedMemory == NULL) {
        return EINVAL;
    }

    *outFileDescriptor = -1;
    *outSharedMemory = NULL;

    const int flags = createIfNeeded ? (O_RDWR | O_CREAT) : O_RDWR;
    const int fileDescriptor = open(kMBITransportSharedMemoryPath, flags, 0666);
    if (fileDescriptor < 0) {
        return errno;
    }

    if (createIfNeeded && fchmod(fileDescriptor, 0666) != 0) {
        const int error = errno;
        close(fileDescriptor);
        return error;
    }

    const size_t mappingSize = sizeof(MBITransportSharedMemory);
    if (createIfNeeded && ftruncate(fileDescriptor, (off_t)mappingSize) != 0) {
        const int error = errno;
        close(fileDescriptor);
        return error;
    }

    struct stat fileStatus;
    if (fstat(fileDescriptor, &fileStatus) != 0) {
        const int error = errno;
        close(fileDescriptor);
        return error;
    }

    if ((size_t)fileStatus.st_size < mappingSize) {
        close(fileDescriptor);
        return EINVAL;
    }

    void *mappedMemory = mmap(NULL, mappingSize, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0);
    if (mappedMemory == MAP_FAILED) {
        const int error = errno;
        close(fileDescriptor);
        return error;
    }

    MBITransportSharedMemory *sharedMemory = (MBITransportSharedMemory *)mappedMemory;
    if (createIfNeeded) {
        MBITransportEnsureInitialized(sharedMemory);
    }

    *outFileDescriptor = fileDescriptor;
    *outSharedMemory = sharedMemory;
    return 0;
}

void MBITransportCloseSharedMemory(int fileDescriptor, MBITransportSharedMemory *sharedMemory) {
    if (sharedMemory != NULL) {
        munmap(sharedMemory, sizeof(MBITransportSharedMemory));
    }

    if (fileDescriptor >= 0) {
        close(fileDescriptor);
    }
}

void MBITransportSetMuted(MBITransportSharedMemory *sharedMemory, uint32_t muted) {
    if (sharedMemory == NULL) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);
    sharedMemory->muted = muted ? 1U : 0U;
}

void MBITransportSetSampleRate(MBITransportSharedMemory *sharedMemory, uint32_t sampleRate) {
    if (sharedMemory == NULL) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);
    sharedMemory->sampleRate = sampleRate > 0 ? sampleRate : kMBITransportDefaultSampleRate;
}

void MBITransportSetBufferFrameSize(MBITransportSharedMemory *sharedMemory, uint32_t bufferFrameSize) {
    if (sharedMemory == NULL) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);
    sharedMemory->bufferFrameSize = bufferFrameSize > 0 ? bufferFrameSize : kMBITransportDefaultBufferFrameSize;
}

void MBITransportSetRunning(MBITransportSharedMemory *sharedMemory, uint32_t running) {
    if (sharedMemory == NULL) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);
    sharedMemory->running = running ? 1U : 0U;
}

void MBITransportSetSourceConnected(MBITransportSharedMemory *sharedMemory, uint32_t sourceConnected) {
    if (sharedMemory == NULL) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);
    sharedMemory->sourceConnected = sourceConnected ? 1U : 0U;
}

void MBITransportWriteMonoFloat(MBITransportSharedMemory *sharedMemory, const float *frames, uint32_t frameCount) {
    if (sharedMemory == NULL || frames == NULL || frameCount == 0) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);

    const uint32_t capacity = sharedMemory->ringFrameCapacity;
    if (capacity == 0) {
        return;
    }

    if (frameCount > capacity) {
        frames += frameCount - capacity;
        frameCount = capacity;
    }

    const uint64_t writeFrameCounter = atomic_load_explicit(&sharedMemory->writeFrameCounter, memory_order_acquire);
    for (uint32_t frameIndex = 0; frameIndex < frameCount; ++frameIndex) {
        const uint64_t absoluteFrameIndex = writeFrameCounter + frameIndex;
        const uint32_t ringIndex = (uint32_t)(absoluteFrameIndex % capacity);
        sharedMemory->ringBuffer[ringIndex] = frames[frameIndex];
    }

    atomic_store_explicit(&sharedMemory->writeFrameCounter, writeFrameCounter + frameCount, memory_order_release);
}

void MBITransportReadMonoFloat(MBITransportSharedMemory *sharedMemory, float *destination, uint32_t frameCount, uint64_t *ioReadFrameCounter) {
    if (destination == NULL || frameCount == 0) {
        return;
    }

    memset(destination, 0, (size_t)frameCount * sizeof(float));

    if (sharedMemory == NULL || ioReadFrameCounter == NULL) {
        return;
    }

    MBITransportEnsureInitialized(sharedMemory);
    if (sharedMemory->muted || !sharedMemory->running || !sharedMemory->sourceConnected) {
        return;
    }

    const uint32_t capacity = sharedMemory->ringFrameCapacity;
    if (capacity == 0) {
        return;
    }

    const uint64_t writeFrameCounter = atomic_load_explicit(&sharedMemory->writeFrameCounter, memory_order_acquire);
    uint64_t readFrameCounter = *ioReadFrameCounter;
    const uint32_t negotiatedBufferFrameSize = sharedMemory->bufferFrameSize > 0 ? sharedMemory->bufferFrameSize : kMBITransportDefaultBufferFrameSize;
    uint64_t targetLeadFrames = (uint64_t)negotiatedBufferFrameSize * 2U;
    if (targetLeadFrames < frameCount) {
        targetLeadFrames = frameCount;
    }
    if (targetLeadFrames > capacity / 2U) {
        targetLeadFrames = capacity / 2U;
    }

    if (readFrameCounter == 0 || readFrameCounter > writeFrameCounter) {
        if (writeFrameCounter > targetLeadFrames) {
            readFrameCounter = writeFrameCounter - targetLeadFrames;
        } else {
            readFrameCounter = 0;
        }
    }

    if ((writeFrameCounter - readFrameCounter) > capacity) {
        readFrameCounter = writeFrameCounter - capacity;
    }

    uint64_t availableFrames = writeFrameCounter - readFrameCounter;
    if (availableFrames == 0) {
        *ioReadFrameCounter = readFrameCounter;
        return;
    }

    if (availableFrames < frameCount && writeFrameCounter >= frameCount) {
        readFrameCounter = writeFrameCounter - frameCount;
        availableFrames = frameCount;
    } else if (availableFrames > frameCount) {
        const uint64_t desiredReadFrameCounter = writeFrameCounter > targetLeadFrames ? (writeFrameCounter - targetLeadFrames) : 0;
        if (desiredReadFrameCounter > readFrameCounter) {
            readFrameCounter = desiredReadFrameCounter;
            availableFrames = writeFrameCounter - readFrameCounter;
        }

        if (availableFrames > frameCount) {
            availableFrames = frameCount;
        }
    }

    const uint32_t framesToCopy = (uint32_t)availableFrames;
    for (uint32_t frameIndex = 0; frameIndex < framesToCopy; ++frameIndex) {
        const uint64_t absoluteFrameIndex = readFrameCounter + frameIndex;
        const uint32_t ringIndex = (uint32_t)(absoluteFrameIndex % capacity);
        destination[frameIndex] = sharedMemory->ringBuffer[ringIndex];
    }

    *ioReadFrameCounter = readFrameCounter + framesToCopy;
}
