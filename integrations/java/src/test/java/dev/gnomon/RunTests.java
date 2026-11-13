package dev.gnomon;

import static org.junit.platform.engine.discovery.DiscoverySelectors.selectClass;
import static org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder.request;

import java.io.PrintWriter;
import org.junit.platform.launcher.core.LauncherFactory;
import org.junit.platform.launcher.listeners.SummaryGeneratingListener;

/** Runs the tests without Maven (test.sh): the JUnit launcher on the cached jars. */
public final class RunTests {
  public static void main(String[] args) {
    SummaryGeneratingListener s = new SummaryGeneratingListener();
    LauncherFactory.create().execute(request().selectors(selectClass(GnomonTest.class)).build(), s);
    s.getSummary().printTo(new PrintWriter(System.out));
    s.getSummary().printFailuresTo(new PrintWriter(System.out), 20);
    System.exit(s.getSummary().getTotalFailureCount() == 0 && s.getSummary().getTestsSucceededCount() > 0 ? 0 : 1);
  }
}
