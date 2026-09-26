package;

import utest.Runner;
import utest.ui.Report;

class RunTests {
	static var failed = 0;

	static function main() {
		var runner = new Runner();
		runner.addCase(new gamessa.tests.MsgPackTest());
		runner.addCase(new gamessa.tests.WireTest());

		runner.onProgress.add(p -> {
			for (a in p.result.assertations) {
				switch (a) {
					case Success(_):
					case _:
						failed++;
				}
			}
		});

		Report.create(runner);
		runner.onComplete.add(_ -> {
			#if interp
			Sys.exit(failed == 0 ? 0 : 1);
			#end
		});
		runner.run();
	}
}
