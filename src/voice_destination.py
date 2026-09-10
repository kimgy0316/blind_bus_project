import speech_recognition as sr
import pyttsx3


def speak(text):
    engine = pyttsx3.init()
    engine.setProperty("rate", 150)
    engine.say(text)
    engine.runAndWait()


def listen_speech(prompt="말씀해 주세요."):
    recognizer = sr.Recognizer()

    with sr.Microphone() as source:
        print(prompt)
        speak(prompt)
        recognizer.adjust_for_ambient_noise(source, duration=1.5)
        audio = recognizer.listen(source, timeout=8, phrase_time_limit=5)

    try:
        text = recognizer.recognize_google(audio, language="ko-KR")
        return text
    except sr.UnknownValueError:
        print("음성을 알아듣지 못했습니다.")
        speak("음성을 알아듣지 못했습니다. 다시 말씀해 주세요.")
        return None
    except sr.RequestError:
        print("음성 인식 서비스에 연결할 수 없습니다.")
        speak("음성 인식 서비스에 연결할 수 없습니다.")
        return None
    except sr.WaitTimeoutError:
        print("입력 시간이 초과되었습니다.")
        speak("입력 시간이 초과되었습니다.")
        return None


def listen_destination():
    return listen_speech("목적지를 말씀해 주세요.")


if __name__ == "__main__":
    destination = listen_destination()

    if destination:
        print(f"인식된 목적지: {destination}")
        speak(f"목적지는 {destination}입니다.")