import 'package:bananafarm/models/draft_job_model.dart';
import 'package:bananafarm/models/job_model.dart';
import 'package:bananafarm/utils/format_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('uniqueJobName', () {
    test('keeps the base name when it is free', () {
      expect(FormatUtils.uniqueJobName('scene', ['other']), 'scene');
    });

    test('suffixes _2, _3 for repeats', () {
      expect(FormatUtils.uniqueJobName('scene', ['scene']), 'scene_2');
      expect(FormatUtils.uniqueJobName('scene', ['scene', 'scene_2']),
          'scene_3');
    });

    test('fills the first gap', () {
      expect(FormatUtils.uniqueJobName('scene', ['scene', 'scene_3']),
          'scene_2');
    });

    test('ignores case, since the name is also a folder', () {
      expect(FormatUtils.uniqueJobName('Scene', ['scene']), 'Scene_2');
    });

    test('falls back to project for an empty base', () {
      expect(FormatUtils.uniqueJobName('  ', []), 'project');
    });
  });

  group('sanitizeFolderName', () {
    test('replaces path and reserved characters', () {
      expect(FormatUtils.sanitizeFolderName('a/b\\c:d*e?f"g<h>i|j'),
          'a_b_c_d_e_f_g_h_i_j');
    });

    test('strips leading and trailing dots and spaces', () {
      expect(FormatUtils.sanitizeFolderName(' .hidden. '), 'hidden');
    });

    test('never returns an empty name', () {
      expect(FormatUtils.sanitizeFolderName('...'), 'job');
    });
  });

  group('job display name', () {
    test('RenderParams round-trips job_name', () {
      final params = RenderParams.fromJson({
        'original_filename': 'scene.blend',
        'job_name': 'Hero shot',
      });
      expect(RenderParams.fromJson(params.toJson()).jobName, 'Hero shot');
      expect(params.displayName, 'Hero shot');
    });

    test('older jobs fall back to the file name without extension', () {
      final params = RenderParams.fromJson({'original_filename': 'scene.blend'});
      expect(params.displayName, 'scene');
    });

    test('DraftJob reads the name from its render params', () {
      final draft = DraftJob(
        id: 'd1',
        blendFilePath: '/tmp/scene.zip',
        originalFilename: 'scene.blend',
        renderParams: {'job_name': 'scene_2'},
        blenderVersion: '5.2.1',
        createdAt: DateTime(2026),
      );
      expect(draft.displayName, 'scene_2');
    });
  });

  test('progress snapshot parses frames_done, defaulting to 0', () {
    expect(RenderProgressSnapshot.fromJson({'frames_done': 3}).framesDone, 3);
    expect(RenderProgressSnapshot.fromJson({}).framesDone, 0);
  });
}
