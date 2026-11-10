import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ATTACHMENT_EXTENSIONS,
  ATTACHMENT_MAX_BYTES,
  attachmentCategory,
  attachmentFileState,
  attachmentMimeType,
  attachmentRejection,
  attachmentSizeLabel,
  newAttachmentPath,
} from './attachments.ts';

test('every required file family has an allowed MIME type', () => {
  const cases: [string, string][] = [
    ['report.pdf', 'application/pdf'],
    ['letter.doc', 'application/msword'],
    ['letter.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
    ['notes.txt', 'text/plain'],
    ['sheet.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
    ['rows.csv', 'text/csv'],
    ['deck.pptx', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'],
    ['photo.jpg', 'image/jpeg'],
    ['photo.png', 'image/png'],
    ['bundle.zip', 'application/zip'],
    ['track.mp3', 'audio/mpeg'],
    ['clip.mp4', 'video/mp4'],
  ];
  for (const [name, mime] of cases) {
    assert.equal(attachmentMimeType(name), mime, name);
  }
});

test('SVG is deliberately excluded', () => {
  assert.equal(attachmentMimeType('drawing.svg'), null);
  assert.ok(!ATTACHMENT_EXTENSIONS.includes('svg'));
  assert.match(attachmentRejection({ name: 'drawing.svg', size: 100 }) ?? '', /not a supported file type/);
});

test('the 20 MB limit and empty files are refused before upload', () => {
  assert.equal(attachmentRejection({ name: 'ok.pdf', size: 1 }), null);
  assert.equal(attachmentRejection({ name: 'ok.pdf', size: ATTACHMENT_MAX_BYTES }), null);
  assert.match(attachmentRejection({ name: 'big.pdf', size: ATTACHMENT_MAX_BYTES + 1 }) ?? '', /larger than 20 MB/);
  assert.match(attachmentRejection({ name: 'empty.pdf', size: 0 }) ?? '', /empty/);
});

test('the path stays inside the owner folder and keeps a safe extension', () => {
  const path = newAttachmentPath('user-1', 'Quarter 4 report.pdf');
  assert.match(path, /^user-1\/\d+-[a-z0-9]+\.pdf$/);
  assert.ok(!path.includes('..'));
});

test('category mirrors the database grouping', () => {
  assert.equal(attachmentCategory('application/pdf'), 'document');
  assert.equal(attachmentCategory('text/csv'), 'spreadsheet');
  assert.equal(attachmentCategory('application/vnd.ms-powerpoint'), 'presentation');
  assert.equal(attachmentCategory('image/png'), 'image');
  assert.equal(attachmentCategory('audio/mpeg'), 'audio');
  assert.equal(attachmentCategory('video/mp4'), 'video');
  assert.equal(attachmentCategory('application/zip'), 'archive');
  assert.equal(attachmentCategory('application/octet-stream'), 'other');
});

test('sizes read the way the panel shows them', () => {
  assert.equal(attachmentSizeLabel(512), '512 B');
  assert.equal(attachmentSizeLabel(2048), '2.0 KB');
  assert.equal(attachmentSizeLabel(2 * 1024 * 1024), '2.0 MB');
  assert.equal(attachmentSizeLabel(20 * 1024 * 1024), '20 MB');
});

test('a missing object is named instead of linked', () => {
  const row = { storage_path: 'user-1/report.pdf' };
  assert.equal(attachmentFileState(row, { present: true, url: 'https://signed.example/x' }), null);
  assert.match(attachmentFileState(row, { present: false, url: null })?.text ?? '', /No file on record/);
  assert.match(attachmentFileState(row, undefined)?.text ?? '', /Preview unavailable/);
  assert.match(attachmentFileState({}, { present: false, url: null })?.text ?? '', /No file on record/);
});
