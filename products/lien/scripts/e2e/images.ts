// images.ts — 写真アップロードの確認に使う小さな JPEG(単色の縞と丸だけ。個人情報なし)
//
// 署名付きアップロード(DESIGN §5.6)で本番の Storage に置き、相手側が署名付き URL で取り戻した
// バイト列が一致するか(SHA-256)を見る。PHOTO_1 / PHOTO_2 は原寸の 1 回目と差し替え、THUMB はサムネ。
// Pillow で作った 64x48 / 32x24 の JPEG(いずれも 1KB 前後)。再生成は不要(中身に意味はない)。

function decode(b64: string): Uint8Array<ArrayBuffer> {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

const PHOTO_1_B64 =
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBMS0dARkVQWnNiUFVtVkVGZIhlbXd7" +
  "gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8" +
  "fHx8fHx8fHz/wAARCAAwAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF" +
  "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW" +
  "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi" +
  "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC" +
  "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm" +
  "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq" +
  "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwBbL+P8KLL+P8KLL+P8KLL+P8KyfU5Asv4/wosv4/wp2nRvK7rGpZuOBWlZaHMisZpFQsBg" +
  "L8xH1os3cai3sZdl/H+FFl/H+Fa6aC8IOydXJx1Xb/jWbFaz2rus8bITjGeh+h70NbjcWtyKy/j/AAosv4/wosv4/wAKLL+P8KH1" +
  "JCy/j/Ciy/j/AAosv4/wosv4/wAKH1A6fTbNLO1RQm2RgDITySf/AK1W6r2Vyt3axyqykkDcB2buKsVqdStbQKjnhSeMpIMg/mPe" +
  "pKbI6xoXchVHUmgZyNsjRySo4wynBHoRmm2X8f4U+CQzTTSsAGdtxx05zTLL+P8ACsn1OQLL+P8ACiy/j/Ciy/j/AAosv4/wofUC" +
  "XS7iS3eRomxnGR2NatnrqzKfOhKsoHKHIP8AhWLZfx/hRZfx/hTu1cqMmtjdXXYZAfKikJHXdgf41mf2hPfFvOYbRghVGAKq2X8f" +
  "4UWX8f4UNvUHJsLL+P8ACiy/j/Ciy/j/AAosv4/wpPqSf//Z";

const PHOTO_2_B64 =
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBMS0dARkVQWnNiUFVtVkVGZIhlbXd7" +
  "gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8" +
  "fHx8fHx8fHz/wAARCAAwAEADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF" +
  "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW" +
  "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi" +
  "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC" +
  "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm" +
  "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq" +
  "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDTsf4/w/rRY/x/h/Wix/j/AA/rRY/x/h/WvNOx9Qsf4/w/rRY/x/h/WnaerOXCgk8Vbs9O" +
  "kjDGVlXdjgc4qowlLZClJLcpWP8AH+H9aLH+P8P61fi0wwhtsoYnHUYqpbwSwM6yoVPGM9DQ4SjuhKSexHY/x/h/Wix/j/D+tFj/" +
  "AB/h/Wix/j/D+tSU+oWP8f4f1osf4/w/rRY/x/h/Wix/j/D+tAPqbFlbLbQKAuHIBc981YqK1mFxAkgIJI+bHY9xUtejG1tDkd76" +
  "hTXRZFKsOKdSMwVSWOAKHa2ojCtFKPKrDDKQCPzptj/H+H9adauZJJnbGWOTj8abY/x/h/WvOOwLH+P8P60WP8f4f1osf4/w/rRY" +
  "/wAf4f1oB9R+myNGZCp9Mj1q9a6kJgd8ZUrjoc5rOsf4/wAP60WP8f4f1q41JR2JlFPc049SjlB8tHyOu7AqnFdy3RfzCMDGFA4F" +
  "QWP8f4f1osf4/wAP60SqSluCglsFj/H+H9aLH+P8P60WP8f4f1osf4/w/rUFPqf/2Q==";

const THUMB_B64 =
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABQODxIPDRQSEBIXFRQYHjIhHhwcHj0sLiQySUBMS0dARkVQWnNiUFVtVkVGZIhlbXd7" +
  "gYKBTmCNl4x9lnN+gXz/2wBDARUXFx4aHjshITt8U0ZTfHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8fHx8" +
  "fHx8fHx8fHz/wAARCAAYACADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF" +
  "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW" +
  "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi" +
  "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC" +
  "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm" +
  "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq" +
  "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDV0/8A5afh/WnaZE7iQqpI457U3T/+Wn4f1rbiVEiVYgAgHGOlQlcxjG5lWtrNbhzKm0HG" +
  "OQf5VDp//LT8P61vEZGDWJahRPcCPGwN8uDnjJoasNxtYZp//LT8P61LplxIiOmcqMYB7UUUiF0JIL6W5DhwqgY+6OtVtP8A+Wn4" +
  "f1oooHe9j//Z";

export const PHOTO_1: Uint8Array<ArrayBuffer> = decode(PHOTO_1_B64);
export const PHOTO_2: Uint8Array<ArrayBuffer> = decode(PHOTO_2_B64);
export const THUMB: Uint8Array<ArrayBuffer> = decode(THUMB_B64);

/**
 * photos バケットの file_size_limit(6 MiB。migration 0008。アプリが受け取る原寸の上限 PartnerPhotoLimits.original と同じ)。
 * これを 1 バイトでも超えるファイルは、署名付きアップロードでも断られる
 */
export const PHOTO_LIMIT_BYTES = 6 * 1024 * 1024;

/** 上限を 1 バイトだけ超える、JPEG の見た目のバイト列(先頭は JPEG の SOI。中身に意味はない)。上限超えの確認用 */
export function oversizedJpegLike(): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(PHOTO_LIMIT_BYTES + 1);
  out.set([0xff, 0xd8, 0xff, 0xe0]);
  return out;
}

/** PNG のシグネチャ(89 50 4E 47 0D 0A 1A 0A)と IHDR の長さで始まる小さなバイト列。JPEG 以外の画像(許可する MIME タイプの確認用) */
export const PNG_LIKE: Uint8Array<ArrayBuffer> = decode("iVBORw0KGgoAAAAN");

/** JPEG の先頭 3 バイト(FF D8 FF)か */
export function looksLikeJpeg(bytes: Uint8Array): boolean {
  return bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
    bytes[2] === 0xff;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
