{******************************************************************************}
{                                                                              }
{       Delphi cross platform socket library                                   }
{                                                                              }
{       Copyright (c) 2017 WiNDDRiVER(soulawing@gmail.com)                     }
{                                                                              }
{       Homepage: https://github.com/winddriver/Delphi-Cross-Socket            }
{                                                                              }
{******************************************************************************}
unit Net.CrossSocket.EpollLoop;

// Ubuntu��������ƺ����ڴ�й©, ����׷�鲻���������Ĳ��ִ�����ɵ�
// �����޷�ȷ����delphi���õ�rtl�⻹������д�Ĵ��������
// ͨ�� LeakCheck ���ܴ��Կ��������ڴ�й©����һ�� AnsiString ����
// �����ܶ�λ������Ĵ���
// �������Լ��Ĵ��������û���κεط��������ʹ�ù����Ƶı���
// ����Linux���а汾��δ����

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Posix.SysSocket, Posix.NetinetIn, Posix.UniStd, Posix.NetDB, Posix.Errno,
  Linux.epoll, Net.SocketAPI, Net.CrossSocket.EventLoop;

type
  // KQUEUE �� EPOLL ���еĲ���
  //    KQUEUE�Ķ�����, һ��Socket��������ж�����¼, ÿ���¼�һ��,
  //    ��һ��� EPOLL ��һ��, EPOLL��ÿ��Socket���ֻ����һ����¼
  //    Ҫ������¼�ʱ, ֻ��Ҫ������¼���λ�������һ����� epoll_ctl ����
  //
  // EPOLLONESHOT ���� epoll ֧���̳߳صĹؼ�
  //    �ò����������¼������������������, ������ͬһ��Socket��ͬһ���¼�
  //    ͬʱ����������̴߳���, ���� epoll ��ÿ�� socket ֻ��һ����¼, ����
  //    һ��Ҫע����� EPOLLONESHOT ������ epoll_ctl, �� epoll_wait ֮��һ��Ҫ�ٴ�
  //    ���� epoll_ctl ����Ҫ���ӵ��¼�
  //
  // EPOLL ��������
  //    ��õ������ǽ�ʵ�ʷ������ݵĶ����ŵ� EPOLLOUT ����ʱ����, ��
  //    �¼��������� Socket ���ͻ����п��пռ��ˡ�IOCP ����ֱ�ӽ������͵����ݼ�
  //    �ص�ͬʱ�Ӹ� WSASend, ������ɺ�ȥ���ûص�����; EPOLL ���Ʋ�һ��, �� EPOLL
  //    ��û������ WSASend �ĺ���, ֻ������ά���������ݼ��ص��Ķ���
  //    EPOLLҪ֧�ֶ��̲߳����������ݱ��봴�����Ͷ���, ����ͬһ�� Socket �Ĳ�������
  //    ���п�����һ���ֻᱻ�������͸��ǵ�
  TEpollLoop = class(TAbstractEventLoop)
  private const
    MAX_EVENT_COUNT = 64;
  private type
    TEpollAction = (epAccept, epConnect, epRead, epWrite);

    PPerIoData = ^TPerIoData;
    TPerIoData = record
      Action: TEpollAction;
      Socket: THandle;
      Callback: TProc<THandle, Boolean>;
    end;

    PSendItem = ^TSendItem;
    TSendItem = record
      Data: PByte;
      Size: Integer;
      Callback: TProc<THandle, Boolean>;
    end;
  private
    FEpollHandle: THandle;
    FIoThreads: TArray<TIoEventThread>;
    FSendQueue: TObjectDictionary<THandle, TList<PSendItem>>;
    class threadvar FEventList: array [0..MAX_EVENT_COUNT-1] of TEPoll_Event;

    function NewIoData: PPerIoData;
    procedure FreeIoData(P: PPerIoData);

    function _EpollCtl(op, fd: Integer; events: Cardinal;
      act: TEpollAction; cb: TProc<THandle, Boolean> = nil): Boolean;

    procedure _ClearSendQueue(ASocketSendQueue: TList<PSendItem>);
    procedure _ClearAllSendQueue;
  protected
    procedure TriggerConnected(ASocket: THandle; AConnectType: Integer); override;
    procedure TriggerDisconnected(ASocket: THandle); override;

    procedure StartLoop; override;
    procedure StopLoop; override;

    function Listen(const AHost: string; APort: Word;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;
    function Connect(const AHost: string; APort: Word;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;
    function Send(ASocket: THandle; const ABuf; ALen: Integer;
      const ACallback: TProc<THandle, Boolean> = nil): Integer; override;

    function ProcessIoEvent: Boolean; override;
  public
    constructor Create(AIoThreads: Integer); override;
    destructor Destroy; override;
  end;

implementation

{ TEpollLoop }

constructor TEpollLoop.Create(AIoThreads: Integer);
begin
  inherited Create(AIoThreads);

  FSendQueue := TObjectDictionary<THandle, TList<PSendItem>>.Create([doOwnsValues]);
end;

destructor TEpollLoop.Destroy;
begin
  System.TMonitor.Enter(FSendQueue);
  try
    _ClearAllSendQueue;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;
  FreeAndNil(FSendQueue);

  inherited Destroy;
end;

function TEpollLoop.NewIoData: PPerIoData;
begin
  System.New(Result);
  FillChar(Result^, SizeOf(TPerIoData), 0);
end;

procedure TEpollLoop.FreeIoData(P: PPerIoData);
begin
  System.Dispose(P);
end;

procedure TEpollLoop._ClearSendQueue(ASocketSendQueue: TList<PSendItem>);
var
  LSendItem: PSendItem;
begin
  for LSendItem in ASocketSendQueue do
    System.Dispose(LSendItem);

  ASocketSendQueue.Clear;
end;

procedure TEpollLoop._ClearAllSendQueue;
var
  LPair: TPair<THandle, TList<PSendItem>>;
begin
  for LPair in FSendQueue do
    _ClearSendQueue(LPair.Value);

  FSendQueue.Clear;
end;

function TEpollLoop._EpollCtl(op, fd: Integer; events: Cardinal;
  act: TEpollAction; cb: TProc<THandle, Boolean>): Boolean;
var
  LEvent: TEPoll_Event;
  LPerIoData: PPerIoData;
begin
  LPerIoData := NewIoData;
  LPerIoData.Action := act;
  LPerIoData.Socket := fd;
  LPerIoData.Callback := cb;

  LEvent.Events := events;
  LEvent.Data.ptr := LPerIoData;
  if (epoll_ctl(FEpollHandle, op, fd, @LEvent) < 0) then
  begin
    FreeIoData(LPerIoData);
    Exit(False);
  end;

  Result := True;
end;

procedure TEpollLoop.StartLoop;
var
  I: Integer;
begin
  if (FIoThreads <> nil) then Exit;

  // epoll_create(size)
  // ��� size ֻҪ���ݴ���0���κ�ֵ������
  // ������˵���еĴ�С�������ڸ�ֵ
  // http://man7.org/linux/man-pages/man2/epoll_create.2.html
  FEpollHandle := epoll_create(MAX_EVENT_COUNT);
  SetLength(FIoThreads, GetIoThreads);
  for I := 0 to Length(FIoThreads) - 1 do
  begin
    FIoThreads[I] := TIoEventThread.Create(Self);
  end;
end;

procedure TEpollLoop.StopLoop;
var
  I: Integer;
begin
  if (FIoThreads = nil) then Exit;

  CloseAll;

  while (FListensCount > 0) or (FConnectionsCount > 0) do Sleep(1);

  Posix.UniStd.__close(FEpollHandle);

  for I := 0 to Length(FIoThreads) - 1 do
  begin
    FIoThreads[I].WaitFor;
    FreeAndNil(FIoThreads[I]);
  end;
  FIoThreads := nil;
end;

procedure TEpollLoop.TriggerConnected(ASocket: THandle; AConnectType: Integer);
var
  LSocketSendQueue: TList<PSendItem>;
begin
  // ��ȡSocket���Ͷ���
  System.TMonitor.Enter(FSendQueue);
  try
    if not FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
    begin
      LSocketSendQueue := TList<PSendItem>.Create;
      FSendQueue.AddOrSetValue(ASocket, LSocketSendQueue);
    end;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;
end;

procedure TEpollLoop.TriggerDisconnected(ASocket: THandle);
var
  LSocketSendQueue: TList<PSendItem>;
begin
  // �Ƴ�Socket���Ͷ���
  System.TMonitor.Enter(FSendQueue);
  try
    if FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
    begin
      // �����ǰSocket�����з��Ͷ���
      _ClearSendQueue(LSocketSendQueue);
      FSendQueue.Remove(ASocket);
    end;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;
end;

function TEpollLoop.Connect(const AHost: string; APort: Word;
  const ACallback: TProc<THandle, Boolean>): Integer;
  procedure _Failed1;
  begin
    {$IFDEF DEBUG}
    __RaiseLastOSError;
    {$ENDIF}

    TriggerConnectFailed(INVALID_HANDLE_VALUE);

    if Assigned(ACallback) then
      ACallback(INVALID_HANDLE_VALUE, False);
  end;

  function _Connect(ASocket: THandle; Addr: PRawAddrInfo): Boolean;
    procedure _Failed2;
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      TSocketAPI.CloseSocket(ASocket);

      TriggerConnectFailed(ASocket);

      if Assigned(ACallback) then
        ACallback(ASocket, False);
    end;
  begin
    if (TSocketAPI.Connect(ASocket, Addr.ai_addr, Addr.ai_addrlen) = 0)
      or (GetLastError = EINPROGRESS) then
    begin
      // EPOLLOUT ֻ�����ж� Connect �ɹ����
      if not _EpollCtl(EPOLL_CTL_ADD, ASocket, EPOLLOUT or EPOLLONESHOT or EPOLLET, epConnect, ACallback) then
      begin
        _Failed2;
        Exit(False);
      end;
    end else
    begin
      _Failed2;
      Exit(False);
    end;

    Result := True;
  end;
var
  LHints: TRawAddrInfo;
  P, LAddrInfo: PRawAddrInfo;
  LSocket: THandle;
begin
  FillChar(LHints, SizeOf(TRawAddrInfo), 0);
  LHints.ai_family := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  LAddrInfo := TSocketAPI.GetAddrInfo(AHost, APort, LHints);
  if (LAddrInfo = nil) then
  begin
    _Failed1;
    Exit(-1);
  end;

  P := LAddrInfo;
  try
    while (LAddrInfo <> nil) do
    begin
      LSocket := TSocketAPI.NewSocket(LAddrInfo.ai_family, LAddrInfo.ai_socktype,
        LAddrInfo.ai_protocol);
      if (LSocket = INVALID_HANDLE_VALUE) then
      begin
        _Failed1;
        Exit(-1);
      end;

      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);
      SetKeepAlive(LSocket);

      if _Connect(LSocket, LAddrInfo) then Exit(0);

      LAddrInfo := PRawAddrInfo(LAddrInfo.ai_next);
    end;
  finally
    TSocketAPI.FreeAddrInfo(P);
  end;

  _Failed1;
  Result := -1;
end;

function TEpollLoop.Listen(const AHost: string; APort: Word;
  const ACallback: TProc<THandle, Boolean>): Integer;
var
  LHints: TRawAddrInfo;
  P, LAddrInfo: PRawAddrInfo;
  LSocket: THandle;

  procedure _Failed;
  begin
    if (LSocket <> INVALID_HANDLE_VALUE) then
      TSocketAPI.CloseSocket(LSocket);

    if Assigned(ACallback) then
      ACallback(LSocket, False);
  end;

  procedure _Success;
  begin
    TriggerListened(LSocket);

    if Assigned(ACallback) then
      ACallback(LSocket, True);
  end;

begin
  LSocket := INVALID_HANDLE_VALUE;
  FillChar(LHints, SizeOf(TRawAddrInfo), 0);

  LHints.ai_flags := AI_PASSIVE;
  LHints.ai_family := AF_UNSPEC;
  LHints.ai_socktype := SOCK_STREAM;
  LHints.ai_protocol := IPPROTO_TCP;
  LAddrInfo := TSocketAPI.GetAddrInfo(AHost, APort, LHints);
  if (LAddrInfo = nil) then
  begin
    _Failed;
    Exit(-1);
  end;

  P := LAddrInfo;
  try
    while (LAddrInfo <> nil) do
    begin
      LSocket := TSocketAPI.NewSocket(LAddrInfo.ai_family, LAddrInfo.ai_socktype,
        LAddrInfo.ai_protocol);
      if (LSocket = INVALID_HANDLE_VALUE) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);

      if (TSocketAPI.Bind(LSocket, LAddrInfo.ai_addr, LAddrInfo.ai_addrlen) < 0) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      if (TSocketAPI.Listen(LSocket) < 0) then
      begin
        _Failed;
        Exit(-1);
      end;

      // �����׽��ֵĶ��¼�
      // ���¼����������������
      if not _EpollCtl(EPOLL_CTL_ADD, LSocket, EPOLLIN or EPOLLONESHOT or EPOLLET, epAccept) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        _Failed;
        Exit(-1);
      end;

      _Success;

      // ����˿ڴ���0�������е�ַͳһ���׸����䵽�Ķ˿�
      if (APort = 0) and (LAddrInfo.ai_next <> nil) then
        Psockaddr_in(LAddrInfo.ai_next.ai_addr).sin_port := Psockaddr_in(LAddrInfo.ai_addr).sin_port;

      LAddrInfo := PRawAddrInfo(LAddrInfo.ai_next);
    end;
  finally
    TSocketAPI.FreeAddrInfo(P);
  end;

  Result := 0;
end;

function TEpollLoop.Send(ASocket: THandle; const ABuf; ALen: Integer;
  const ACallback: TProc<THandle, Boolean>): Integer;
var
  LSocketSendQueue: TList<PSendItem>;
  LSendItem: PSendItem;

  procedure _Failed;
  begin
    System.TMonitor.Enter(LSocketSendQueue);
    try
      _ClearSendQueue(LSocketSendQueue);
    finally
      System.TMonitor.Exit(LSocketSendQueue);
    end;

    if Assigned(ACallback) then
      ACallback(ASocket, False);

    if (TSocketAPI.CloseSocket(ASocket) = 0) then
      TriggerDisconnected(ASocket);
  end;

begin
  // ��ȡSocket���Ͷ���
  System.TMonitor.Enter(FSendQueue);
  try
    if not FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
    begin
      LSocketSendQueue := TList<PSendItem>.Create;
      FSendQueue.AddOrSetValue(ASocket, LSocketSendQueue);
    end;
  finally
    System.TMonitor.Exit(FSendQueue);
  end;

  // ��Ҫ���͵����ݼ��ص�����Socket���Ͷ�����
  LSendItem := System.New(PSendItem);
  LSendItem.Data := @ABuf;
  LSendItem.Size := ALen;
  LSendItem.Callback := ACallback;
  System.TMonitor.Enter(LSocketSendQueue);
  try
    LSocketSendQueue.Add(LSendItem);
  finally
    System.TMonitor.Exit(LSocketSendQueue);
  end;

  // ���� EPOLLOUT, �����¼�����ʱ�����������ͻ����п��пռ���
  // �����¼�������ִ��ʵ�ʵķ��Ͷ���
  if not _EpollCtl(EPOLL_CTL_MOD, ASocket, EPOLLOUT or EPOLLONESHOT or EPOLLET, epWrite) then
  begin
    _Failed;
    Exit(-1);
  end;

  Result := ALen;
end;

function TEpollLoop.ProcessIoEvent: Boolean;
  procedure _HandleAccept(ASocket: THandle; APerIoData: PPerIoData);
  var
    LRet: Integer;
    LSocket: THandle;
  begin
    while True do
    begin
      LRet := TSocketAPI.Accept(ASocket, nil, nil);

      // Acceptʧ��
      // EAGAIN ��Ҫ����
      // EMFILE ���̵��ļ�����Ѿ�������
      if (LRet <= 0) then
      begin
//        LRet := GetLastError;
//        Writeln('accept failed:', LRet);
        Break;
      end;

      LSocket := LRet;
      TSocketAPI.SetNonBlock(LSocket, True);
      TSocketAPI.SetReUseAddr(LSocket, True);
      SetKeepAlive(LSocket);

      // ���ӽ����������Socket�Ķ��¼�
      if not _EpollCtl(EPOLL_CTL_ADD, LSocket, EPOLLIN or EPOLLONESHOT or EPOLLET, epRead) then
      begin
        {$IFDEF DEBUG}
        __RaiseLastOSError;
        {$ENDIF}
        TSocketAPI.CloseSocket(LSocket);
        Continue;
      end;

      TriggerConnected(LSocket, CT_ACCEPT);
    end;

    // ���¼��� EPOLLIN, �Լ�������������
    if not _EpollCtl(EPOLL_CTL_MOD, ASocket, EPOLLIN or EPOLLONESHOT or EPOLLET, epAccept) then
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      TSocketAPI.CloseSocket(ASocket);
    end;
  end;

  procedure _HandleRead(ASocket: THandle; APerIoData: PPerIoData);
  var
    LRcvd: Integer;
  begin
    while True do
    begin
      LRcvd := TSocketAPI.Recv(ASocket, FRecvBuf[0], RCV_BUF_SIZE, MSG_NOSIGNAL);

      // �Է������Ͽ�����
      if (LRcvd = 0) then
      begin
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
        Break;
      end;

      if (LRcvd < 0) then
      begin
        // ��Ҫ����
        if _Again(GetLastError) then Break;

        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);

        Exit;
      end;

      TriggerReceived(ASocket, @FRecvBuf[0], LRcvd);

      if (LRcvd < RCV_BUF_SIZE) then Break;
    end;

    // ���¼��� EPOLLIN �� EPOLLOUT, �Լ������ջ���������
    // �������ͬʱ���� EPOLLIN �� EPOLLOUT, ��Ϊ�� TriggerReceived �����ִ����
    // �������ݵĲ���, ���øò�����û���ü����� epoll_wait, ��ô���������ֻ����
    // EPOLLIN, �ͻᵼ�´����͵������޷�������
    // ֻ���� _HandleRead ���б�Ҫ������
    if not _EpollCtl(EPOLL_CTL_MOD, ASocket, EPOLLIN or EPOLLOUT or EPOLLONESHOT or EPOLLET, epRead) then
    begin
      if (TSocketAPI.CloseSocket(ASocket) = 0) then
        TriggerDisconnected(ASocket);
    end;
  end;

  procedure _HandleConnect(ASocket: THandle; APerIoData: PPerIoData);
    procedure _Success;
    begin
      TriggerConnected(ASocket, CT_CONNECT);

      if Assigned(APerIoData.Callback) then
        APerIoData.Callback(ASocket, True);
    end;

    procedure _Failed;
    begin
      {$IFDEF DEBUG}
      __RaiseLastOSError;
      {$ENDIF}
      TSocketAPI.CloseSocket(ASocket);

      TriggerConnectFailed(ASocket);

      if Assigned(APerIoData.Callback) then
        APerIoData.Callback(ASocket, False);
    end;
  begin
    // Connectʧ��
    if (TSocketAPI.GetError(ASocket) <> 0) then
    begin
      _Failed;
      Exit;
    end;

    _Success;

    // ���ӳɹ�, �������¼�
    if not _EpollCtl(EPOLL_CTL_MOD, ASocket, EPOLLIN or EPOLLONESHOT or EPOLLET, epRead) then
    begin
      _Failed;
      Exit;
    end;
  end;

  procedure _HandleWrite(ASocket: THandle; APerIoData: PPerIoData);
  var
    LSocketSendQueue: TList<PSendItem>;
    LSendItem: PSendItem;
    LSent: Integer;
    LCallback: TProc<THandle, Boolean>;

    procedure _ReadContinue;
    begin
      if not _EpollCtl(EPOLL_CTL_MOD, ASocket, EPOLLIN or EPOLLONESHOT or EPOLLET, epRead) then
      begin
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
      end;
    end;

    function _WriteContinue: Boolean;
    begin
      Result := _EpollCtl(EPOLL_CTL_MOD, ASocket, EPOLLOUT or EPOLLONESHOT or EPOLLET, epWrite);
      if not Result then
      begin
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
      end;
    end;

    procedure _Failed;
    begin
      // ���ûص�
      if Assigned(LCallback) then
        LCallback(ASocket, False);
    end;

    procedure _Success;
    begin
      // ���ͳɹ�, �Ƴ��ѷ��ͳɹ�������
      System.Dispose(LSendItem);
      if (LSocketSendQueue.Count > 0) then
        LSocketSendQueue.Delete(0);

      // ��������л�������, ��������
      if (LSocketSendQueue.Count > 0) then
        _WriteContinue
      else
        _ReadContinue;

      // ���ûص�
      if Assigned(LCallback) then
        LCallback(ASocket, True);
    end;

  begin
    LCallback := nil;

    if (FSendQueue = nil) then
    begin
      _ReadContinue;
      Exit;
    end;

    // ��ȡSocket���Ͷ���
    System.TMonitor.Enter(FSendQueue);
    try
      if not FSendQueue.TryGetValue(ASocket, LSocketSendQueue) then
      begin
        // �����������¼�
        _ReadContinue;
        Exit;
      end;
    finally
      System.TMonitor.Exit(FSendQueue);
    end;

    if (LSocketSendQueue = nil) then
    begin
      _ReadContinue;
      Exit;
    end;

    // ��ȡSocket���Ͷ����еĵ�һ������
    System.TMonitor.Enter(LSocketSendQueue);
    try
      if (LSocketSendQueue.Count <= 0) then
      begin
        // �����������¼�
        _ReadContinue;
        Exit;
      end;

      LSendItem := LSocketSendQueue.Items[0];
      LCallback := LSendItem.Callback;

      // ȫ���������
      if (LSendItem.Size <= 0) then
      begin
        _Success;
        Exit;
      end;

      // ��������
      LSent := TSocketAPI.Send(ASocket, LSendItem.Data^, LSendItem.Size, MSG_NOSIGNAL);

      // ���ͳɹ�
      if (LSent > 0) then
      begin
        Inc(LSendItem.Data, LSent);
        Dec(LSendItem.Size, LSent);
      end else
      // ���ӶϿ����ʹ���
      if (LSent = 0) or not _Again(GetLastError) then
      begin
        if (TSocketAPI.CloseSocket(ASocket) = 0) then
          TriggerDisconnected(ASocket);
        _Failed;
        Exit;
      end;

      // �������� EPOLLOUT �¼�
      // EPOLLOUT �������������
      if not _WriteContinue then
        _Failed;
    finally
      System.TMonitor.Exit(LSocketSendQueue);
    end;
  end;
var
  LRet, I: Integer;
  LEvent: TEPoll_Event;
  LSocket: THandle;
  LPerIoData: PPerIoData;
begin
  // �����ָ����ʱʱ��, ��ʹ�������߳̽� epoll ����ر�, epoll_wait Ҳ���᷵��
  LRet := epoll_wait(FEpollHandle, @FEventList[0], MAX_EVENT_COUNT, 100);
  if (LRet < 0) then
  begin
    LRet := GetLastError;
    Writeln('error:', LRet);
    // EINTR, epoll_wait ���ñ�ϵͳ�жϴ��, ���Խ�������
    Exit(LRet = EINTR);
  end;

  for I := 0 to LRet - 1 do
  begin
    LEvent := FEventList[I];
    LPerIoData := LEvent.Data.ptr;

    if (LPerIoData = nil) then
    begin
      Writeln('LPerIoData is nil');
      Continue;
    end;

    try
      LSocket := LPerIoData.Socket;

      // �쳣�¼�
      if (LEvent.Events and EPOLLERR <> 0) then
      begin
        Writeln('event:', IntToHex(LEvent.Events), ' socket:', LPerIoData.Socket, ' action:', Integer(LPerIoData.Action));

        if Assigned(LPerIoData.Callback) then
          LPerIoData.Callback(LSocket, False);

        if (TSocketAPI.CloseSocket(LSocket) = 0) then
          TriggerDisconnected(LSocket);

        Continue;
      end;

      // ���ݿɶ�
      if (LEvent.Events and EPOLLIN <> 0) then
      begin
        case LPerIoData.Action of
          // ���µĿͻ�������
          epAccept: _HandleAccept(LSocket, LPerIoData);
        else
          // �յ�������
          _HandleRead(LSocket, LPerIoData);
        end;
      end;

      // ���ݿ�д
      if (LEvent.Events and EPOLLOUT <> 0) then
      begin
        case LPerIoData.Action of
          // ���ӳɹ�
          epConnect: _HandleConnect(LSocket, LPerIoData);
        else
          // ���Է�������
          _HandleWrite(LSocket, LPerIoData);
        end;
      end;
    finally
      FreeIoData(LPerIoData);
    end;
  end;

  Result := True;
end;

end.
