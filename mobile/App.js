import React, { useMemo, useState } from "react";
import {
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View
} from "react-native";
import * as Speech from "expo-speech";

const routeSteps = [
  {
    title: "출발 준비",
    body: "현재 위치에서 가장 가까운 버스 정류장으로 이동합니다.",
    speak: "안내를 시작합니다. 현재 위치에서 가장 가까운 버스 정류장으로 이동하세요."
  },
  {
    title: "정류장 도착",
    body: "30-1번 버스가 약 3분 후 도착 예정입니다.",
    speak: "정류장에 도착했습니다. 30-1번 버스가 약 3분 후 도착 예정입니다."
  },
  {
    title: "버스 확인",
    body: "AI가 버스 전광판을 인식하여 30-1번 버스를 확정했습니다.",
    speak: "접근 중인 버스는 30-1번입니다. 목표 버스가 맞습니다."
  },
  {
    title: "탑승 안내",
    body: "버스 기사에게 시각장애인 탑승 요청 알림을 보냅니다.",
    speak: "버스 기사에게 탑승 요청 알림을 보냈습니다. 안전하게 탑승하세요."
  },
  {
    title: "하차 안내",
    body: "목적지까지 세 정류장 남았습니다. 하차 전 음성으로 다시 안내합니다.",
    speak: "목적지까지 세 정류장 남았습니다. 하차 준비 시 다시 안내하겠습니다."
  }
];

function speak(text, setVoiceLog) {
  const message = text.trim();

  if (!message) {
    return;
  }

  setVoiceLog(message);
  Speech.stop();
  Speech.speak(message, {
    language: "ko-KR",
    rate: 0.95,
    pitch: 1.0
  });
}

function ActionButton({ label, variant = "primary", onPress }) {
  return (
    <TouchableOpacity
      accessibilityRole="button"
      style={[styles.button, styles[`${variant}Button`]]}
      onPress={onPress}
      activeOpacity={0.82}
    >
      <Text style={[styles.buttonText, variant === "secondary" && styles.secondaryButtonText]}>
        {label}
      </Text>
    </TouchableOpacity>
  );
}

function Metric({ label, value }) {
  return (
    <View style={styles.metric}>
      <Text style={styles.metricLabel}>{label}</Text>
      <Text style={styles.metricValue}>{value}</Text>
    </View>
  );
}

function StepItem({ step, index, active }) {
  return (
    <View style={[styles.step, active && styles.activeStep]}>
      <View style={styles.stepIndex}>
        <Text style={styles.stepIndexText}>{index + 1}</Text>
      </View>
      <View style={styles.stepContent}>
        <Text style={styles.stepTitle}>{step.title}</Text>
        <Text style={styles.stepBody}>{step.body}</Text>
      </View>
    </View>
  );
}

export default function App() {
  const [destination, setDestination] = useState("천안역");
  const [currentStep, setCurrentStep] = useState(0);
  const [voiceLog, setVoiceLog] = useState("목적지를 입력하고 경로 찾기 버튼을 누르세요.");
  const [systemStatus, setSystemStatus] = useState("시연 모드");
  const [readNumber, setReadNumber] = useState("30-1");
  const [confirmedNumber, setConfirmedNumber] = useState("30-1");
  const [decisionConfidence, setDecisionConfidence] = useState("0.97");

  const remainingStops = useMemo(() => {
    return Math.max(0, routeSteps.length - currentStep - 2);
  }, [currentStep]);

  const runSpeech = (message) => speak(message, setVoiceLog);

  const setStep = (nextStep) => {
    const safeStep = Math.min(routeSteps.length - 1, Math.max(0, nextStep));
    setCurrentStep(safeStep);
    runSpeech(routeSteps[safeStep].speak);
  };

  const findRoute = () => {
    const place = destination.trim() || "천안역";
    setSystemStatus("경로 안내 중");
    setCurrentStep(0);
    runSpeech(`${place}까지의 버스 경로를 찾았습니다. 30-1번 버스를 이용합니다. 예상 소요 시간은 18분입니다.`);
  };

  const mockVoiceDestination = () => {
    setDestination("천안역");
    setSystemStatus("목적지 입력 완료");
    runSpeech("음성 입력 시연입니다. 목적지를 천안역으로 설정했습니다.");
  };

  const checkBus = () => {
    setReadNumber("30-1");
    setConfirmedNumber("30-1");
    setDecisionConfidence("0.97");
    runSpeech("AI가 버스 전광판을 확인했습니다. 읽은 번호와 확정 번호 모두 30-1번입니다.");
  };

  const notifyDriver = () => {
    runSpeech("기사 알림을 보냈습니다. 시각장애인 승객이 탑승할 예정입니다.");
  };

  return (
    <SafeAreaView style={styles.safeArea}>
      <StatusBar barStyle="light-content" backgroundColor="#132033" />
      <View style={styles.header}>
        <View>
          <Text style={styles.title}>시각장애인 버스 안내 앱</Text>
          <Text style={styles.subtitle}>음성 목적지 입력, 버스 API, AI 노선번호 판정</Text>
        </View>
        <Text style={styles.status}>{systemStatus}</Text>
      </View>

      <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
        <View style={styles.card}>
          <Text style={styles.sectionTitle}>목적지 설정</Text>
          <Text style={styles.label}>목적지</Text>
          <TextInput
            value={destination}
            onChangeText={setDestination}
            style={styles.input}
            placeholder="목적지를 입력하세요"
            placeholderTextColor="#8b96aa"
            accessibilityLabel="목적지 입력"
          />
          <View style={styles.buttonGrid}>
            <ActionButton label="음성 입력 시연" onPress={mockVoiceDestination} />
            <ActionButton label="시연 목적지" variant="secondary" onPress={mockVoiceDestination} />
          </View>
          <ActionButton label="경로 찾기 및 음성 안내" variant="blue" onPress={findRoute} />
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionTitle}>길 안내</Text>
          <View style={styles.metricGrid}>
            <Metric label="예상 시간" value="18분" />
            <Metric label="이용 버스" value="30-1" />
            <Metric label="남은 정류장" value={`${remainingStops}개`} />
          </View>
          {routeSteps.map((step, index) => (
            <StepItem
              key={step.title}
              step={step}
              index={index}
              active={index === currentStep}
            />
          ))}
          <View style={styles.buttonGrid}>
            <ActionButton label="이전 안내" variant="secondary" onPress={() => setStep(currentStep - 1)} />
            <ActionButton label="다음 안내" onPress={() => setStep(currentStep + 1)} />
          </View>
          <ActionButton label="현재 안내 다시 듣기" variant="blue" onPress={() => runSpeech(routeSteps[currentStep].speak)} />
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionTitle}>실시간 버스 정보</Text>
          <View style={styles.busCard}>
            <Text style={styles.busNumber}>30-1</Text>
            <Text style={styles.busMeta}>도착 예정: 3분 후{"\n"}현재 위치: 두 정류장 전</Text>
            <View style={styles.aiRow}>
              <Text style={styles.aiLabel}>읽은 번호</Text>
              <Text style={styles.aiValue}>{readNumber}</Text>
            </View>
            <View style={styles.aiRow}>
              <Text style={styles.aiLabel}>확정 번호</Text>
              <Text style={styles.aiValue}>{confirmedNumber}</Text>
            </View>
            <View style={styles.aiRow}>
              <Text style={styles.aiLabel}>판정 신뢰도</Text>
              <Text style={styles.aiValue}>{decisionConfidence}</Text>
            </View>
          </View>
          <View style={styles.buttonGrid}>
            <ActionButton label="버스 확인 안내" onPress={checkBus} />
            <ActionButton label="기사 알림" variant="orange" onPress={notifyDriver} />
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.sectionTitle}>음성 안내 로그</Text>
          <View style={styles.voiceLog}>
            <Text style={styles.voiceLogText}>{voiceLog}</Text>
          </View>
          <ActionButton label="안내 시작" variant="blue" onPress={() => setStep(0)} />
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: "#132033"
  },
  header: {
    paddingHorizontal: 18,
    paddingVertical: 16,
    backgroundColor: "#132033",
    flexDirection: "row",
    justifyContent: "space-between",
    gap: 12
  },
  title: {
    color: "#ffffff",
    fontSize: 22,
    fontWeight: "900"
  },
  subtitle: {
    color: "#cbd5e8",
    marginTop: 4,
    fontSize: 13
  },
  status: {
    alignSelf: "flex-start",
    color: "#eaf2ff",
    borderColor: "rgba(255,255,255,0.45)",
    borderWidth: 1,
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 6,
    fontSize: 12,
    fontWeight: "700"
  },
  screen: {
    flex: 1,
    backgroundColor: "#f4f6fb"
  },
  content: {
    padding: 14,
    gap: 14
  },
  card: {
    backgroundColor: "#ffffff",
    borderWidth: 1,
    borderColor: "#d9dfeb",
    borderRadius: 8,
    padding: 14
  },
  sectionTitle: {
    fontSize: 19,
    fontWeight: "900",
    color: "#172033",
    marginBottom: 12
  },
  label: {
    color: "#64708a",
    fontWeight: "800",
    marginBottom: 8
  },
  input: {
    height: 50,
    borderWidth: 1,
    borderColor: "#c8d0df",
    borderRadius: 8,
    paddingHorizontal: 12,
    fontSize: 18,
    color: "#172033"
  },
  buttonGrid: {
    flexDirection: "row",
    gap: 10,
    marginTop: 12
  },
  button: {
    flex: 1,
    minHeight: 50,
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 12,
    marginTop: 12
  },
  primaryButton: {
    backgroundColor: "#0b7a5c"
  },
  secondaryButton: {
    backgroundColor: "#e9eef7",
    borderWidth: 1,
    borderColor: "#c8d0df"
  },
  blueButton: {
    backgroundColor: "#1458d4"
  },
  orangeButton: {
    backgroundColor: "#b35c00"
  },
  buttonText: {
    color: "#ffffff",
    fontSize: 15,
    fontWeight: "900",
    textAlign: "center"
  },
  secondaryButtonText: {
    color: "#172033"
  },
  metricGrid: {
    flexDirection: "row",
    gap: 10
  },
  metric: {
    flex: 1,
    borderWidth: 1,
    borderColor: "#d9dfeb",
    borderRadius: 8,
    padding: 12,
    backgroundColor: "#fbfcff"
  },
  metricLabel: {
    color: "#64708a",
    fontWeight: "800",
    marginBottom: 6,
    fontSize: 12
  },
  metricValue: {
    color: "#172033",
    fontSize: 20,
    fontWeight: "900"
  },
  step: {
    flexDirection: "row",
    gap: 10,
    borderWidth: 1,
    borderColor: "#d9dfeb",
    borderRadius: 8,
    padding: 12,
    marginTop: 10
  },
  activeStep: {
    borderColor: "#1458d4",
    backgroundColor: "#f7faff"
  },
  stepIndex: {
    width: 34,
    height: 34,
    borderRadius: 17,
    backgroundColor: "#e9f7f2",
    alignItems: "center",
    justifyContent: "center"
  },
  stepIndexText: {
    color: "#075f48",
    fontWeight: "900"
  },
  stepContent: {
    flex: 1
  },
  stepTitle: {
    color: "#172033",
    fontWeight: "900",
    marginBottom: 4
  },
  stepBody: {
    color: "#64708a",
    lineHeight: 20
  },
  busCard: {
    borderWidth: 1,
    borderColor: "#bed7ca",
    borderRadius: 8,
    padding: 14,
    backgroundColor: "#f2fbf7"
  },
  busNumber: {
    color: "#14823b",
    fontSize: 38,
    fontWeight: "900"
  },
  busMeta: {
    color: "#365446",
    lineHeight: 21,
    marginTop: 8,
    marginBottom: 10
  },
  aiRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    borderBottomWidth: 1,
    borderBottomColor: "#d6e6dc",
    paddingVertical: 9
  },
  aiLabel: {
    color: "#304b3d"
  },
  aiValue: {
    color: "#172033",
    fontWeight: "900"
  },
  voiceLog: {
    minHeight: 110,
    backgroundColor: "#101827",
    borderRadius: 8,
    padding: 12,
    marginBottom: 4
  },
  voiceLogText: {
    color: "#eff6ff",
    lineHeight: 22
  }
});
