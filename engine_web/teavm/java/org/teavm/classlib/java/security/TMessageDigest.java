package org.teavm.classlib.java.security;

import java.security.NoSuchAlgorithmException;

/**
 * TeaVM 0.14.1 の classlib に無い MessageDigest（Mesh3d と Texture3d の中身の鍵が使う）。
 * SHA-256 だけを持つ。ほかの名前は JDK と同じく NoSuchAlgorithmException で断る。
 */
public final class TMessageDigest {
    private static final int BLOCK_BYTES = 64;
    private static final int DIGEST_BYTES = 32;
    private static final int[] ROUND_CONSTANTS = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    };

    private final int[] state = new int[8];
    private final int[] schedule = new int[64];
    private final byte[] pending = new byte[BLOCK_BYTES];
    private int pendingLength;
    private long totalBytes;

    private TMessageDigest() {
        reset();
    }

    public static TMessageDigest getInstance(String algorithm) throws NoSuchAlgorithmException {
        if (!"SHA-256".equalsIgnoreCase(algorithm)) {
            throw new NoSuchAlgorithmException(algorithm + " MessageDigest not available");
        }
        return new TMessageDigest();
    }

    public String getAlgorithm() {
        return "SHA-256";
    }

    public int getDigestLength() {
        return DIGEST_BYTES;
    }

    public void reset() {
        state[0] = 0x6a09e667;
        state[1] = 0xbb67ae85;
        state[2] = 0x3c6ef372;
        state[3] = 0xa54ff53a;
        state[4] = 0x510e527f;
        state[5] = 0x9b05688c;
        state[6] = 0x1f83d9ab;
        state[7] = 0x5be0cd19;
        pendingLength = 0;
        totalBytes = 0;
    }

    public void update(byte input) {
        pending[pendingLength++] = input;
        totalBytes++;
        if (pendingLength == BLOCK_BYTES) {
            compress(pending, 0);
            pendingLength = 0;
        }
    }

    public void update(byte[] input) {
        update(input, 0, input.length);
    }

    public void update(byte[] input, int offset, int length) {
        if (offset < 0 || length < 0 || length > input.length - offset) {
            throw new IllegalArgumentException("Input buffer too short");
        }
        totalBytes += length;
        int from = offset;
        int left = length;
        if (pendingLength > 0) {
            int taken = Math.min(left, BLOCK_BYTES - pendingLength);
            System.arraycopy(input, from, pending, pendingLength, taken);
            pendingLength += taken;
            from += taken;
            left -= taken;
            if (pendingLength < BLOCK_BYTES) {
                return;
            }
            compress(pending, 0);
            pendingLength = 0;
        }
        while (left >= BLOCK_BYTES) {
            compress(input, from);
            from += BLOCK_BYTES;
            left -= BLOCK_BYTES;
        }
        System.arraycopy(input, from, pending, 0, left);
        pendingLength = left;
    }

    public byte[] digest(byte[] input) {
        update(input);
        return digest();
    }

    public byte[] digest() {
        long totalBits = totalBytes * 8;
        pending[pendingLength++] = (byte) 0x80;
        if (pendingLength > BLOCK_BYTES - 8) {
            fillPendingWithZeros(BLOCK_BYTES);
            compress(pending, 0);
            pendingLength = 0;
        }
        fillPendingWithZeros(BLOCK_BYTES - 8);
        for (int i = 0; i < 8; i++) {
            pending[BLOCK_BYTES - 1 - i] = (byte) (totalBits >>> (8 * i));
        }
        compress(pending, 0);
        byte[] result = new byte[DIGEST_BYTES];
        for (int i = 0; i < 8; i++) {
            result[4 * i] = (byte) (state[i] >>> 24);
            result[4 * i + 1] = (byte) (state[i] >>> 16);
            result[4 * i + 2] = (byte) (state[i] >>> 8);
            result[4 * i + 3] = (byte) state[i];
        }
        reset();
        return result;
    }

    private void fillPendingWithZeros(int end) {
        while (pendingLength < end) {
            pending[pendingLength++] = 0;
        }
    }

    private void compress(byte[] block, int offset) {
        int[] w = schedule;
        for (int i = 0; i < 16; i++) {
            int at = offset + 4 * i;
            w[i] = (block[at] & 0xff) << 24 | (block[at + 1] & 0xff) << 16 | (block[at + 2] & 0xff) << 8 | (block[at + 3] & 0xff);
        }
        for (int i = 16; i < 64; i++) {
            int a = w[i - 15];
            int b = w[i - 2];
            int s0 = Integer.rotateRight(a, 7) ^ Integer.rotateRight(a, 18) ^ (a >>> 3);
            int s1 = Integer.rotateRight(b, 17) ^ Integer.rotateRight(b, 19) ^ (b >>> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        int a = state[0];
        int b = state[1];
        int c = state[2];
        int d = state[3];
        int e = state[4];
        int f = state[5];
        int g = state[6];
        int h = state[7];
        for (int i = 0; i < 64; i++) {
            int s1 = Integer.rotateRight(e, 6) ^ Integer.rotateRight(e, 11) ^ Integer.rotateRight(e, 25);
            int choice = (e & f) ^ (~e & g);
            int t1 = h + s1 + choice + ROUND_CONSTANTS[i] + w[i];
            int s0 = Integer.rotateRight(a, 2) ^ Integer.rotateRight(a, 13) ^ Integer.rotateRight(a, 22);
            int majority = (a & b) ^ (a & c) ^ (b & c);
            int t2 = s0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        state[0] += a;
        state[1] += b;
        state[2] += c;
        state[3] += d;
        state[4] += e;
        state[5] += f;
        state[6] += g;
        state[7] += h;
    }
}
